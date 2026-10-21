# Monitor contínuo do PDV 0.4.0 — Windows 7/10/11

Monitor local do pinpad TEF e da impressora para registrar mudanças de porta COM, desconexões observáveis, problemas informados pelo Windows e tentativas de recuperação. Mantém histórico local e pode enviar os registros para a central do Conecta.

**Piloto em validação.** Os testes com dados simulados passaram no macOS com PowerShell 7.5.4 e no Windows com PowerShell 5.1 pelo [GitHub Actions](https://github.com/diegoaf-ti/feirao-pdv-monitor/actions). A interface, a coleta nativa e os equipamentos reais ainda precisam ser validados no caixa. Comece acompanhado pelo suporte, mantendo a recuperação desarmada.

Para correção automática e atualização assinada, consulte o [guia do piloto 0.4.0](GUIA-PILOTO-V3.md) e a [documentação do atualizador](ATUALIZACAO-AUTOMATICA.md). O [guia v2](GUIA-PILOTO-V2.md) preserva as instruções anteriores.

## Abrir e deixar funcionando

1. Extraia toda a pasta do pacote no computador do caixa.
2. Abra **Monitor.cmd** usando o mesmo usuário do Windows que opera o PDV.
3. Aguarde a primeira coleta. Selecione o pinpad e a impressora corretos e salve um vínculo para cada função. A COM esperada deve ser a porta confirmada para aquele caixa; impressora por USB nativa/rede pode ficar sem COM esperada.
4. Use **Iniciar automaticamente neste usuário...** para copiar os arquivos do programa para `%LOCALAPPDATA%\Feirao\PdvMonitor\programa` e criar um atalho na pasta Inicializar do usuário atual.
5. Feche a janela. O monitor continua funcionando no ícone ao lado do relógio. Abra-o novamente por esse ícone.

**Fechar a janela apenas oculta.** Para encerrar a coleta, use **Encerrar monitor** ou a opção de sair no ícone ao lado do relógio. Se uma coleta estiver em andamento, o aplicativo aguarda sua conclusão antes de terminar.

O início automático ocorre **depois do login desse usuário no Windows**. Não é um serviço de sistema e não coleta enquanto o computador está desligado, antes do login ou após sair da conta. Também não eleva privilégios automaticamente. Não é necessário deixar a janela aberta.

A instalação é opcional: `Monitor.cmd` também funciona de forma portátil. Não há instalador `.exe`. Os iniciadores aplicam `ExecutionPolicy Bypass` somente ao processo aberto; não alteram a política permanente do computador. Se uma política da organização impedir a execução, o suporte deve providenciar a liberação.

Para remover o início automático, execute `DesinstalarMonitor.ps1` pelo PowerShell no mesmo usuário. Isso remove somente o atalho criado pelo monitor e preserva programa, perfis, chave protegida e logs. Encerre a instância já aberta pelo ícone da bandeja.

## Correção automática e atualização do monitor

A central pode autorizar por instalação o ajuste de fiscalDevice para uma correspondência COM homologada. A tentativa exige PDV/TEF fechados, nenhuma impressão pendente, três leituras estáveis e nova conferência; a API usa ticket, comparação do valor anterior e auditoria transacional. No fluxo autônomo, a configuração aguarda reabertura e validação da impressão; esse fluxo não fecha o caixa. A tentativa assistida descrita a seguir acrescenta o fechamento e a reabertura confirmados localmente. Nenhum dos fluxos altera a COM do Windows.

A versão 0.4.0 acrescenta **Corrigir e reabrir Nerus...** no monitor local. Depois de consultar a divergência pela API, o operador confirma que finalizou ou cancelou venda e pagamento. A tentativa identifica o executável pelo atalho **Nerus** da Área de Trabalho, pede fechamento normal, aguarda a saída, usa a correção transacional existente e reabre uma vez. A aplicação pode recusar o fechamento; não há encerramento forçado ou confirmação automática dos diálogos. Resultado incerto da escrita bloqueia a reabertura automática. A consulta nova da API precisa estar publicada.

A versão 0.3.1 explica nos registros por que uma tentativa não pode avançar: inventário incompleto, impressora sem vínculo, identidade ausente, porta sem correspondência homologada ou conflito. Instâncias ausentes de conexões anteriores não são escolhidas para corrigir o caixa. Esses avisos não confirmam falha de impressão nem autorizam associar equipamentos apenas pelo nome/modelo.

Atualizações aprovadas podem ser recebidas automaticamente após uma instalação inicial desta versão. O monitor valida a assinatura, aplica seu próprio programa e restaura o anterior se a nova versão falhar. As duas opções começam desativadas e são independentes. A integração v3 do Conecta/API precisa ser publicada antes de habilitá-las; por solicitação do usuário, essa publicação está pendente.

## Alertas para o suporte e inventário da empresa

O histórico prioriza problemas que exigem atenção. A enumeração de portas continua local a cada 15 segundos, mas dispositivos normais, filas e reservas COM não são enviados repetidamente. Sinais genéricos WMI não geram uma ocorrência por mudança.

**Os alertas de COM exigem vínculo salvo.** Na primeira instalação, selecione a instância exata do pinpad e da impressora, confirme a porta que o Nerus espera para aquele caixa e use **Salvar vínculo**. Sem esse passo o monitor coleta o patrimônio e as falhas graves do Windows, mas não sabe qual dispositivo deveria estar em qual COM. Nome/modelo ou VID/PID sozinho não identificam uma unidade com segurança.

| Fonte | Frequência e informação |
| --- | --- |
| COM e dispositivos vinculados | Consulta local a cada 15 segundos, além da duração da coleta. Divergência da COM, ocupação por outra instância presente, desconexão e falha Windows são confirmadas em três leituras completas consecutivas. |
| Persistência e resolução | Um mesmo problema gera um alerta até a condição mudar. Três leituras normais geram resolução. Presença ou código desconhecido não se tornam prova de desconexão ou recuperação. |
| Patrimônio da máquina | Coleta no início e a cada seis horas: identificação WMI, nome do computador, fabricante/modelo/série, Windows, CPU, RAM/módulos, discos, volume do sistema e adaptadores físicos. Documento próprio de até 32 KiB. |
| Atualização do patrimônio | Envio inicial, mudança do hardware ou renovação após 24 horas. Horário de captura, boot, espaço livre e ordem dos dispositivos não criam uma mudança de patrimônio. Falha de consulta preserva o último inventário válido. |
| Falhas graves Windows | Canais relevantes já habilitados, somente níveis crítico/erro de disco, WHEA, energia, USB, serial e impressão. Consulta a cada 60 segundos, até 100 eventos por canal, com repetidos agrupados por canal/provedor/código por dez minutos. |
| Monitor e manutenção | Início/encerramento, sinal de atividade a cada minuto, mudanças na cobertura de coleta e tentativas/resultados de recuperação. Decisões desarmadas não são publicadas como incidentes. |

O patrimônio fica separado da lista de ocorrências na central. `MachineInventory` e `HardwareChanged` são resumos informativos. Não há nova remessa periódica de uma linha por driver ou reserva COM. Reservas não provam que a COM está ocupada; um dispositivo histórico ausente não é anunciado como conflito concreto.

Eventos Windows preservam somente horário, canal, provedor, número de registro, código e nível. Mensagens completas, documentos e propriedades livres não são lidos. O monitor não habilita canais desligados. A cobertura inicial começa nos últimos dois minutos; limpeza/rotação, falhas de acesso e limite de coleta ficam explícitos. O agrupamento é por metadados e não determina a causa de uma falha. Não há promessa de capturar todo evento passado.

O inventário usa uma lista explícita de campos. Não coleta usuário, product key, IPs, programas instalados, arquivos, dados de pagamento ou mensagens WMI livres. Arrays têm limites de 16 itens e a cobertura reduzida é informada; o JSON nunca é cortado para caber no transporte.

As consultas não abrem portas seriais, não realizam pagamentos ou impressões de teste e não leem arquivos de transações/configuração do SiTef. Uma observação indica o que o Windows informou, sem provar a comunicação com o Nerus ou a causa da falha.

### Particularidades do Windows 7

O monitor usa consultas WMI/Registro compatíveis com a sintaxe do Windows PowerShell 2.0. A presença física pode ficar **não confirmada**; `Status=OK` ou código de problema `0` não comprovam que o equipamento esteja conectado ou disponível para o Nerus. A enumeração de uma porta também não comprova que outro processo consiga abri-la. Essas limitações estão documentadas em [Win32_PnPEntity](https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-pnpentity).

No Windows 10/11 com PowerShell 5.1 e módulo PnpDevice, utiliza o inventário PnP. Quando os requisitos não estão disponíveis, recorre à coleta legada. Uma falha de consulta é registrada como coleta incompleta, sem concluir automaticamente que todos os dispositivos desapareceram.

O aviso [Win32_DeviceChangeEvent](https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-devicechangeevent) é genérico: pode indicar outra mudança de hardware e não substitui uma evidência específica do pinpad/impressora.

## Histórico local e exportação

Os dados ficam em `%LOCALAPPDATA%\Feirao\PdvMonitor`:

- `logs\monitor-*.csv`: histórico técnico, com data, sessão, sequência e identificador único de cada ocorrência.
- `monitor.xml`: perfis e configurações locais; não contém a chave de envio em texto aberto.
- `cursores.xml`: posições de leitura dos canais Windows.
- `recuperacoes.xml`: histórico recente das tentativas de reinício.
- `status.txt`: último estado informado pelo monitor.
- `inventario-hardware.json`: último patrimônio estruturado válido; incluído na exportação.
- `inventario-estado.xml`: hash estático e referência da última inclusão para envio.
- `hardware-pendente.xml`: único documento patrimonial aguardando confirmação; fica fora da exportação, assim como a fila histórica e a credencial.

Os CSVs são separados por dia/sessão e giram em torno de 5 MB por arquivo. A limpeza mantém até 30 dias e busca limitar o conjunto a 100 MB, removendo os arquivos antigos; o arquivo em uso é preservado. Exporte o atendimento antes de alcançar essa retenção se precisar guardar o histórico por mais tempo.

Use **Exportar diagnóstico...** para copiar os logs e os arquivos técnicos exportáveis para uma pasta escolhida. A exportação não inclui a chave de envio. O resultado pode conter identificadores/números de série dos equipamentos, nomes de filas e loja/caixa; compartilhe pelo canal interno de suporte.

Quando houver falha, anote também o horário, a operação em andamento e a mensagem apresentada pelo Nerus/SiTef. O monitor não enxerga o estado interno das DLLs e não substitui os testes oficiais do fornecedor.

## Central do Conecta

O administrador cadastra a instalação em **Aplicações → Monitor do PDV**. A tela fornece o endereço HTTPS da API, loja, caixa, **ID da instalação** e **token** de 64 caracteres hexadecimais. O token é mostrado somente na criação; mantenha ID e token nos campos separados.

No Windows, abra **Configurar envio central...** e preencha esses mesmos dados. O monitor monta a autenticação de transporte com ID e token; não cole os dois juntos no campo do token. O endpoint termina em `/api/pdv-monitor/ingest`, considerando o prefixo efetivamente publicado da API.

A chave é protegida pelo Windows para o usuário atual com DPAPI e fica fora dos diagnósticos exportáveis. Executar com outra conta não permite reutilizar automaticamente a chave da conta original. O monitor não recebe usuário/senha de banco de dados. A proteção segue o escopo [CurrentUser](https://learn.microsoft.com/en-us/dotnet/api/system.security.cryptography.dataprotectionscope).

O envio usa HTTPS com validação normal de certificado. No Windows 7, a disponibilidade real de TLS 1.2 depende da configuração e das atualizações instaladas; o teste no caixa deve confirmar a conexão. Não há opção de ignorar certificado.

Se ficar sem internet, a coleta local continua e os eventos pendentes ficam em uma fila em disco. Cada envio contém até 50 registros e respeita o limite de 256 KB. O documento patrimonial usa o protocolo v2 e pode ser enviado sozinho ou junto aos eventos. Somente HTTP **204** confirma atomicamente os eventos e o inventário anexo, permitindo remover os itens confirmados da fila. O arquivo patrimonial só é removido se ainda corresponder ao conteúdo exato enviado. Repetições preservam os identificadores, e o servidor descarta duplicatas idênticas sem sobrescrever o primeiro conteúdo. Erros de rede usam novas tentativas com espera progressiva.

A fila tem limites de **100 MB e 20 mil registros**. Ao atingir a capacidade, o monitor preserva os pendentes e sinaliza que novos eventos não entraram na fila central; os CSVs locais continuam sujeitos à sua própria retenção. Não há descarte silencioso da fila antiga. Falhas de credencial ou de envio também ficam visíveis no estado do monitor. Resolva a causa e exporte os logs se necessário.

Na central, **Online** significa contato recebido nos últimos cinco minutos, com horário do servidor. Não confirma que o TEF esteja aprovando pagamentos nem que a impressora esteja funcionando. O painel permite filtrar loja/caixa, consultar ocorrências e revogar uma instalação; não executa comandos no computador. Uma chave perdida deve ser revogada e substituída por novo cadastro.

A API, sua migração de banco e o painel precisam ser publicados separadamente antes de ativar esse envio. O monitor pode funcionar apenas com logs locais enquanto essa preparação não estiver concluída.

**Ordem da atualização:** aplique primeiro a migração de inventário no banco do ambiente escolhido, depois publique a API que aceita `schemaVersion:2` e o painel. Depois atualize os monitores Windows. A API continua aceitando agentes v1. Um agente novo contra API antiga preserva a fila, porém o envio v2 será recusado até a atualização. As instruções e os arquivos SQL ficam em `PDV_MONITOR.md` no repositório da API; o Windows não executa migrações. O piloto deste projeto usa o ambiente `nxstore.shop` e a base `conecta_feirao_hm`; isso não autoriza alterar outra base.

## Recuperação: desarmada por padrão

A recuperação local de dispositivo é separada da integração Nerus descrita acima: ela só pode solicitar ao Windows o reinício de uma **instância exata previamente vinculada**, durante uma manutenção autorizada pelo operador. Não fixa COM, não muda parâmetros/SQL do Nerus, não encerra processos, não reinicia o PC e não descarrega DLLs.

Para avaliar essa função no caixa piloto, o suporte deve identificar os equipamentos, encerrar o PDV/TEF, verificar que não há transação ou impressão pendente, habilitar a recuperação apenas no perfil desejado e informar os nomes exatos dos processos do PDV/TEF. Depois pode usar **Armar recuperação por 15 minutos...**. A janela expira automaticamente e não permanece armada ao reabrir o monitor.

A política exige simultaneamente:

- Windows 10 versão 2004 ou posterior/Windows 11 e monitor aberto como administrador. Windows 7 permanece sem recuperação.
- Manutenção manual válida, dispositivo presente com identidade exata e erro Windows elegível observado por três coletas consecutivas.
- Inventário/presença confiáveis, sem divergência/conflito de COM e sem processos bloqueadores ou trabalhos de impressão identificados.
- Histórico de tentativas íntegro e gravação local disponível.
- Intervalo mínimo de 15 minutos entre tentativas, no máximo duas por hora e três por sessão.

Uma COM diferente, presença desconhecida ou falha relatada somente pelo Nerus não autoriza reinício. O monitor não conhece todos os estados internos de uma venda; a janela de manutenção e a indicação correta dos processos são indispensáveis. O início automático comum não solicita elevação, portanto essa ação não passa a funcionar por conta própria após o login.

O resultado registra se o Windows aceitou o pedido. Depois, o suporte deve validar a comunicação nos utilitários oficiais e no PDV; retorno de sucesso do Windows não comprova recuperação do TEF. A disponibilidade do comando está na documentação do [PnPUtil](https://learn.microsoft.com/en-us/windows-hardware/drivers/devtest/pnputil-command-syntax).

## Diagnóstico portátil anterior

`Iniciar.cmd` continua abrindo o piloto anterior de consulta: interface completa no Windows compatível e `DiagnosticoLegado.ps1` no modo legado. É uma ferramenta separada para consultas pontuais/exportação, sem a instalação ou o histórico contínuo do novo monitor. Para deixar a coleta funcionando na bandeja, use **Monitor.cmd**.

## Verificação técnica e piloto

Os testes abaixo usam mocks e não consultam/reiniciam dispositivos reais. Exigem PowerShell 5.1 ou posterior para o ambiente de testes, mesmo quando verificam módulos escritos para PowerShell 2.0:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\TestsLegado.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\TestsMonitorColeta.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\TestsMonitorPolitica.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\TestsMonitorTransporte.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\TestsMonitorHost.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\TestsMonitorRuntime.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\TestsMonitorInventario.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\TestsPnpProperties.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\TestsMonitorNerus.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\TestsMonitorNerusRestart.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\TestsMonitorNerusRestartFlow.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\TestsMonitorAtualizacao.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\TestsMonitorIntegracaoAutomacao.ps1
```

A aprovação dos testes simulados no macOS e no Windows PowerShell 5.1 não comprova funcionamento do Windows PowerShell 2.0, interface de bandeja, DPAPI, coleta WMI/Event Log, TLS/HTTPS, driver ou recuperação real.

Para atualizar uma instalação existente, encerre o monitor pelo ícone da bandeja, extraia todos os arquivos da nova versão e abra `Monitor.cmd` com o mesmo usuário e pasta de dados. Confirme a configuração central e os vínculos existentes; a chave permanece protegida para esse usuário. Se usa início automático, use novamente o botão de instalação para atualizar os arquivos copiados. Não execute uma versão antiga em paralelo.

No primeiro caixa, validar abertura no usuário comum, presença/COM comparadas com o Gerenciador de Dispositivos, ocultação sem encerrar, exportação, início após novo login e saída explícita. Fora de uma venda, testar desconectar/reconectar um equipamento por vez, falta de rede/reenvio sem duplicar, mudança para offline na central e revogação. Conferir a presença desconhecida no Windows 7 e os avisos de consulta indisponível. Confirme que o patrimônio aparece na central, que não surgem novos snapshots periódicos e que a COM esperada de cada perfil está correta. Fora de venda, simule divergência apenas no perfil do monitor, observe o alerta após três leituras, restaure a referência e confira a resolução. Não renumere a COM do Windows para esse teste. Só depois avaliar recuperação durante manutenção acompanhada.

Registre Windows, modelo do pinpad e da impressora, versões do driver, Nerus e CliSiTef. A documentação de [Get-WinEvent](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.diagnostics/get-winevent?view=powershell-5.1) explica as consultas aos canais Windows. A possibilidade de `AUTO_USB` deve ser validada separadamente com o fornecedor da [CliSiTef](https://dev.softwareexpress.com.br/docs/clisitef/configuracao_da_porta/), conforme equipamento e biblioteca instalados.
