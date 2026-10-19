# Piloto 0.3.0 — correção Nerus e atualização automática

O monitor implementa a tentativa de ajuste de fiscalDevice pela API e a atualização assinada do próprio programa. O Conecta e a API precisam receber a integração v3 antes de habilitar essas opções. A publicação dessas duas aplicações está aguardando a decisão da equipe; esta entrega não atualiza nxstore.shop nem executa migrações.

## Preparar a central quando a publicação for autorizada

1. Integrar as alterações da API e do painel fornecidas separadamente. Elas complementam os PRs anteriores de inventário e incidentes.
2. Confirmar DB_NAME_CONECTA=conecta_feirao_hm e DB_NAME_SQLPARAM=teste_sqlparam para o piloto. O código recusa schema ausente ou inválido; não assume sqlparam de produção.
3. Aplicar as tabelas originais, a migração de hardware v2 e database/ddl/create_pdv_monitor_automation.sql da integração v3, nessa ordem, conforme já existam no ambiente. As migrações são manuais.
4. Publicar API v3 e painel, mantendo HTTPS. Para distribuir versões, montar um diretório de pacotes aprovados e configurar PDV_MONITOR_UPDATE_DIR com seu caminho absoluto no servidor/container. A API precisa apenas ler esse diretório; em Docker, usar volume somente leitura.
5. Copiar para esse diretório o ZIP imutável 0.3.0.zip e o manifesto assinado latest.xml. Publicar primeiro o ZIP, depois substituir o manifesto de forma atômica.

Uma API antiga continua recebendo telemetria v1/v2. Rotas de automação ausentes não habilitam ações por dedução: o monitor mantém a coleta normal.

## Instalar o primeiro monitor uma vez

A versão antiga não possui o mecanismo de atualização. É necessária uma instalação inicial:

1. Encerrar o monitor anterior pela bandeja, preservando %LOCALAPPDATA%\Feirao\PdvMonitor.
2. Extrair 0.3.0.zip completo e abrir Monitor.cmd com o usuário que opera o caixa.
3. Usar **Iniciar automaticamente neste usuário...**. O instalador copia os 20 arquivos, fixa a chave pública e cria um iniciador estável fora da pasta substituída nas atualizações.
4. Confirmar os vínculos locais da impressora e do pinpad. O InstanceId usado na central deve corresponder ao vínculo local **Impressora**; não escolher apenas pelo nome/modelo.
5. Preservar instalação e chave de envio existentes. Não revogar nem recadastrar apenas por atualizar.

O início continua ocorrendo após login. A atualização automática exige a cópia instalada em programa; a versão portátil informa que precisa ser instalada.

## Habilitar a correção da impressora

Abrir **Instalações → Automação** no caixa correto. A opção começa desativada.

- Conferir loja, caixa e máquina inventariada. A política se vincula à identidade física da máquina; trocar o computador exige desativar e ativar novamente.
- Informar a identidade exata da impressora e correspondências homologadas entre COM e fiscalDevice. O caso observado foi **COM4 → 3 no CX4901**. Não há fórmula automática para outras portas.
- Informar os nomes reais de todos os processos que utilizam impressora/PDV/TEF. Os nomes de demonstração não são configuração pronta para lojas.
- Escolher dias e janela de até duas horas no mesmo dia, fora do atendimento. Ativar somente após essas conferências.

O monitor aguarda três observações completas e estáveis: equipamento presente e saudável, sem conflito de porta, processos cadastrados fechados e nenhuma impressão pendente. Pede um ticket de dez segundos, consulta novamente o Windows e só então solicita a alteração.

A API confere política, horário, máquina, dispositivo, evidências e limites. Altera somente a linha única fiscalDevice pela chave completa (modulo, terminal, varname), comparando o conteúdo anterior. A tabela precisa ser InnoDB. Alteração, resultado e histórico são gravados na mesma transação.

Timeout não autoriza criar outra alteração: o mesmo ticket é consultado/repetido até conhecer o resultado. Há intervalo de quinze minutos e limite de duas tentativas por hora. Falha ao salvar estado local bloqueia novas ações.

**Configuração gravada; aguarda reabertura** indica apenas ajuste do parâmetro. Abrir o Nerus e confirmar impressão. O monitor não encerra PDV, recarrega DLL, renumera COM ou executa pagamento/impressão de teste. Lista de processos e janela reduzem o risco, mas não substituem um contrato de manutenção do ERP: evitar iniciar o PDV durante a breve conferência do piloto.

## Habilitar atualização automática

Marcar **Receber versões aprovadas automaticamente neste computador**. Essa opção independe da correção Nerus e não exige impressora configurada.

O monitor consulta versões a cada seis horas e verifica assinatura RSA-SHA256, chave pública fixada, versão, validade, tamanho e hash. A extração aceita somente arquivos conhecidos do programa. Pacote inválido mantém a versão atual.

A instalação aguarda o próprio monitor ficar sem coleta em andamento, manutenção manual ou correção Nerus pendente. Apenas o monitor reinicia. Configuração, chave DPAPI, fila e logs ficam fora de programa.

A versão nova deve confirmar coleta saudável em até noventa segundos. Falha reabre a anterior e coloca a versão rejeitada em quarentena. O iniciador estável restaura um backup validado se faltar energia entre as duas renomeações. Instalação, falha e reversão são enviadas como eventos.

## Liberar as próximas versões aprovadas

Alterar código no GitHub não instala automaticamente um commit nos caixas:

1. Atualizar o número em PdvMonitor.Version.psm1 e monitor-version.txt, por exemplo 0.3.1.
2. Rodar testes e revisar alterações.
3. Gerar o pacote offline com a chave privada fora do repositório:

~~~text
python3 tools/criar-pacote-atualizacao.py --source PASTA_FONTE --output PASTA_NOVA --version 0.3.1 --private-key CAMINHO_CHAVE_PRIVADA
~~~

4. Conferir manifesto/ZIP; copiar o ZIP ao diretório oficial da API e trocar latest.xml atomicamente.

A chave privada não integra repositório, pacote ou servidor de distribuição. Preservá-la com acesso restrito e backup seguro. A chave pública fixada não é substituída por download; troca de chave exige procedimento administrativo próprio.

## Conferir antes de ampliar

Testar acompanhado: correspondência conhecida, ausência de venda, aplicação do parâmetro e impressão após reabrir. Exercitar porta desconhecida, conflito, abertura do PDV entre preparação/confirmação, falta de rede e resposta perdida. Conferir preservação de edição manual concorrente.

Testar atualização assinada, recusa de pacote alterado, reabertura, reversão sem saúde e preservação de chave/fila/configuração. Windows 7 pode não confirmar presença e pode exigir componentes para TLS/ZIP; desconhecido bloqueia correção e não autoriza reduzir verificações.
