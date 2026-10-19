# Atualização automática do monitor

A partir do pacote 0.3.0, uma instalação pode receber versões aprovadas sem novo acesso remoto ao caixa. É necessária uma primeira instalação manual dessa versão, com a chave pública de confiança incluída no pacote. Depois, habilite **Atualizar monitor automaticamente** na política da instalação no Conecta.

O monitor consulta a central a cada seis horas. Alterações no GitHub só chegam aos caixas depois de criar e publicar um pacote aprovado e assinado. O programa continua funcionando com a versão atual quando está sem internet, quando a chave foi revogada ou quando a versão oferecida falha nas validações.

## O que é substituído

A atualização substitui apenas os arquivos próprios do monitor em `%LOCALAPPDATA%\Feirao\PdvMonitor\programa`. Configuração, perfis, políticas, logs, fila de envio e credencial DPAPI permanecem na pasta de dados, fora de `programa`.

A troca espera o monitor ficar sem coleta ou recuperação em andamento, fecha apenas o monitor e abre a nova versão em segundo plano. Não fecha o Nerus/TEF, não reinicia o computador e não requer abrir portas COM. A atualização é independente da habilitação da recuperação dos dispositivos.

A versão nova precisa concluir uma rodada saudável e confirmar sua versão e o hash assinado em até 90 segundos. Se isso falhar, o executor encerra apenas o processo filho do monitor que ele iniciou e restaura a versão anterior. Uma versão revertida fica bloqueada localmente para evitar repetir o mesmo problema; publique uma versão maior para uma nova tentativa.

## Publicação de uma versão aprovada

1. Atualize a versão literal em `PdvMonitor.Version.psm1` e execute os testes Windows PowerShell 5.1, incluindo `TestsMonitorAtualizacao.ps1`. O primeiro uso de autoatualização deve ser feito em um caixa piloto.
2. Execute o gerador offline com Python 3 e OpenSSL. A chave privada RSA XML ou PEM fica fora do repositório, da pasta fonte e da pasta servida pela API. O arquivo `atualizacoes-chave-publica.xml` da fonte deve corresponder a essa chave.

```text
python3 tools/criar-pacote-atualizacao.py --source CAMINHO_FONTE --output PASTA_NOVA --version 0.3.1 --private-key CAMINHO_PRIVADO --valid-days 30
```

3. Copie somente `0.3.1.zip` e `latest.xml` para o diretório de versões aprovadas configurado no servidor em `PDV_MONITOR_UPDATE_DIR`. Envie primeiro o ZIP e substitua `latest.xml` por último, de forma atômica. O diretório deve permitir leitura à API e escrita somente ao responsável pela publicação.
4. Confira o resultado no histórico da instalação antes de habilitar outras lojas. Publicar uma versão nunca exige modificar a chave de telemetria dos caixas.

O gerador usa lista explícita de arquivos; não inclui testes, logs, parâmetros do Nerus, credenciais nem a chave privada. Não substitui uma saída já existente. Também verifica que o módulo de versão coincide com a versão aprovada.

## Validações locais

- Canal fixo `piloto` e versão numérica `x.y.z` estritamente maior que a atual.
- HTTPS com validação normal do certificado, TLS 1.2 e mesma origem da API configurada. Não segue redirecionamentos.
- Mesmo token DPAPI da telemetria: `Authorization: Bearer agentId.token`. A chave não é colocada no manifesto, nos argumentos de processo nem em logs.
- Manifesto de até 32 KiB, payload XML assinado com RSA-SHA256, sem DTD/entidades externas. A validade máxima de uma assinatura é 90 dias.
- Chave pública instalada uma única vez em `atualizacoes-chave-publica.xml` na pasta de dados. O download não instala nem troca essa chave. A troca de chave exige distribuir um novo pacote manualmente por um canal confiável.
- ZIP de até 20 MiB, hash SHA256 e tamanho exatos. Extração limitada a 60 MiB e 4 MiB por arquivo, com lista explícita de arquivos. Caminhos, links, duplicatas, ZIP64, arquivos operacionais e expansão além do tamanho declarado são rejeitados.
- Diretórios temporários, backup e estado ficam em `atualizacoes`. O último resultado está em `atualizacoes\estado.xml` e a versão revertida em `atualizacoes\versao-rejeitada.txt`.

## Requisitos e recuperação local

A máquina deve permitir escrita na instalação do próprio usuário e disponibilizar TLS 1.2, RSA-SHA256 e compilação C# do PowerShell. Em Windows antigo sem esses recursos, a atualização falha sem reduzir a segurança da conexão; a versão atual continua monitorando. Não há instalação automática de .NET, drivers ou componentes do Windows.

O mecanismo foi testado com arquivos temporários e processos simulados; isso não substitui o teste no Windows com os equipamentos reais. O pacote portátil pode consultar e baixar uma versão, mas a substituição automática exige uma instalação na pasta `programa` do monitor.

O atalho instalado usa `IniciarMonitorInstalado.ps1` na pasta de dados, fora de `programa`. Se houver interrupção de energia entre a renomeação da versão antiga e a colocação da nova, esse iniciador recupera a versão anterior na próxima abertura do usuário: exige um journal de atualização em andamento e confere os hashes SHA256, tamanhos e lista completa de 20 arquivos do backup, registrados antes da troca. Não restaura um backup alterado, incompleto, com caminhos/links ou enquanto outro atualizador mantém o lock exclusivo. Uma restauração coloca a versão interrompida em quarentena.

O iniciador estável é instalado manualmente uma vez. Nas atualizações seguintes, sua cópia na pasta de dados só é substituída por uma troca atômica depois que a versão nova confirma a saúde. Se essa cópia falhar, o iniciador anterior permanece e o resultado registra `UpdateHealthConfirmedBootstrapRetained`; o monitor novo continua funcionando. Se os metadados/backup estiverem danificados, o iniciador informa o bloqueio em `falha-inicializacao-monitor.txt` e pede a reinstalação. Preserve a pasta de dados. Bloqueio de arquivos por outro processo ou pelo antivírus também aparece como falha de aplicação/reversão em `estado.xml`.

## Testes offline

```text
powershell.exe -NoProfile -File TestsMonitorAtualizacao.ps1
python3 tools/test_criar_pacote_atualizacao.py
```

Os testes usam RSA temporária, pastas temporárias e mocks de HTTP, DPAPI e processos; não consultam equipamentos nem executam instalação/recuperação real. O gerador e o leitor PowerShell também foram conferidos com o mesmo ZIP e manifesto reais, assinados com uma chave de teste descartável.
