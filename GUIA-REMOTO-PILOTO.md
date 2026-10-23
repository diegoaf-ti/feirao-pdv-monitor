# Preparação local do piloto de suporte remoto

O broker `PdvMonitor.Remoto.psm1` continua isolado de rede/processos. A integração acrescenta transporte HTTPS, extensão Windows e ganchos no Host/Runtime, desligados por padrão; consulte [GUIA-REMOTO-INTEGRACAO.md](GUIA-REMOTO-INTEGRACAO.md). A geração do candidato 0.7.0 foi autorizada: o ZIP é preparado localmente no macOS, com núcleo de 22 arquivos e preparação administrativa separada. Não houve execução em Windows, instalação nas lojas nem publicação do Conecta/API. A primeira migração de 0.6 para 0.7 precisa de `Instalar.cmd`, com o monitor fechado e o mesmo usuário; veja [GUIA-INSTALACAO-0.7.md](GUIA-INSTALACAO-0.7.md).

A extensão só é importada do caminho fixo `%PROGRAMDATA%\Feirao\PdvMonitorRemoto\app`, após conferir ACLs/proprietário, ancestrais, reparse points e hard links. `piloto-remoto\windows\PrepararRemoto.cmd`, executado explicitamente como administrador, copia somente código e modelos inativos para essa raiz; não recebe nem cria PKI, perfil ativo ou binários UltraVNC/stunnel. Preparação existente requer revisão. O atualizador do usuário não altera a extensão administrativa, e uma cópia do adaptador em `LOCALAPPDATA` não é importada.

## Contrato isolado do broker

O broker aceita um pedido de suporte com campos fechados, registra sua identidade antes de qualquer decisão e prepara o consentimento para o Host local. O contrato puro é descrito a seguir; a integração de rede/processos fica nos adaptadores externos. A função padrão isolada de console retorna **indisponível**: não existe consentimento automático nem inferência de console desbloqueada. Os testes substituem esse adaptador por evidências simuladas.

O preparo exige detectar versão do Windows e arquitetura localmente e aprovar as dependências exatas. `Get-PdvMonitorRemotePreparationAssessment` bloqueia evidência desconhecida, SO/arquitetura fora dos perfis e dependências não homologadas; seu adaptador isolado padrão retorna desconhecido. A integração admite estações Windows 7 SP1 (`6.1.7601`) e Windows 10/11 (`10.0`, build >= `10240`), x86/x64, processo na arquitetura nativa e CLR 4 com .NET >= 4.6.2 (`Release >= 394802`); recomenda-se WMF 5.1 com .NET 4.8. Windows 7 sem SP1, Vista, 8/8.1, Server, ARM e processo de arquitetura divergente ficam bloqueados. O inventário da instalação da loja 49 precisa confirmar o perfil antes do ensaio. O XML administrativo schema `2` exige `PlatformProfile` exato e hashes/assinaturas/aprovação específicos; os schemas XML da API não mudam. Elegibilidade no código não significa conjunto homologado: ainda não há bundle atual stunnel x86 construído, assinado ou validado. Consulte [COMPATIBILIDADE-WINDOWS7.md](piloto-remoto/windows/COMPATIBILIDADE-WINDOWS7.md).

A decisão exige um desafio novo, a mesma sessão/usuário/instância do Host e, ao aprovar, confirmação explícita de que não há venda ou pagamento em andamento. O botão padrão do diálogo integrado é **Não permitir**; fechar ou deixar expirar não equivale a aprovar. Não automatizar o clique em nenhum diálogo do UltraVNC ou do Windows.

O módulo não tem cliente HTTP, VNC, captura de tela, controle de teclado/mouse, execução de comandos, instalação ou inicialização de processos/serviços. Suas mensagens de decisão ao adaptador externo são:

| Kind | Payload | Uso autorizado |
|---|---|---|
| `SubmitConsent` | `sessionId`, `requestId`, `nonce`, `decision` | POST HTTPS na rota de consentimento do próprio agente |
| `SubmitClosedStatus` | `sessionId`, `status: closed` | Encerrar apenas o registro desta sessão neste protótipo |

Não existem mensagens `Run`, `Start`, `Ready`, executável, argumentos, host, porta, caminho remoto ou script. Aprovação central resulta em `authorized`, com `Connected=false` e `TransportActivationSupported=false`; esse é o resultado do broker puro, que não aciona processos. O coordenador externo já implementado usa o adaptador nativo e mantém seu próprio estado `LocalTransportActive`. **Nenhum desses sinais comprova tela visível ou atendimento concluído.**

A integração externa já acrescenta verificação de identidade dos binários, journal antes de cada efeito, evidência de mTLS e lease, supervisão/fechamento do transporte e confirmação de parada antes do envio de `closed`. O broker puro não substitui essas verificações. Consulte o guia de integração e o README do piloto para o fluxo completo e os limites da homologação.

## Contrato alinhado com a API

`GET /agent/remote/request`: HTTP 204 ou um pedido com os campos abaixo. A camada de transporte deve desserializar JSON/XML em um dicionário simples e aplicar os limites antes de chamar o broker.

- `SessionId`, `AgentId`, `RequestId`: UUID canônico; `RequestId=SessionId` e `AgentId` deve ser o próprio agente.
- `RequestedAt`, `ExpiresAt`: ISO 8601 com fuso. Janela positiva de no máximo 120 segundos; pedido futuro acima de cinco segundos é rejeitado.
- `SessionMaxSeconds`: inteiro entre 30 e 900.
- `Mode`: somente `control`. Este campo indica a capacidade solicitada; não habilita operação sem consentimento. A API usa `assisted` para o tipo de atendimento.
- `TechnicianId`: texto decimal positivo, até 20 dígitos; `TechnicianName`: 1 a 160 caracteres.
- `Reason`: 10 a 500 caracteres; nome e motivo não aceitam controles, quebra de linha ou caracteres invisíveis de formatação.
- `Nonce`: 32 bytes em base64url canônico, sem padding.

`POST /agent/remote/consent`: decisão `approved` ou `denied`, idempotente para a mesma sessão/nonce/decisão. Resposta normalizada pelo transporte: `{Id, Status, ExpiresAt, ConsentExpiresAt}`. A negativa admite `ExpiresAt` vazio/null. A aprovação exige prazo válido e nunca ultrapassa localmente 900 segundos desde o clique, mesmo que o servidor proponha prazo posterior.

Fechamento e consulta central de sessão interrompida precisam devolver um estado terminal autenticado: `{Id, Status}` com `closed`, `ended`, `failed`, `cancelled`, `expired` ou `denied`. `approved` e `ready` não resolvem uma interrupção. O adaptador de VNC/túnel já exige também evidência de encerramento dos processos locais próprios antes de confirmar o fechamento central.

O transporte deve reutilizar a autenticação HTTPS do agente, rejeitar redirecionamentos e validar o certificado normalmente. Nonce/desafio não podem entrar em logs, telemetria, URLs ou exportação. A obtenção de `Get-PdvMonitorRemoteCommand` é uma operação interna sensível, destinada somente ao adaptador HTTP.

Não serializar/exportar o objeto interno `Context`, que contém material temporário do pedido. Usar exclusivamente `Get-PdvMonitorRemoteSnapshot` e os eventos de lista fechada. O nonce é limpo da memória do contexto ao receber confirmação central ou pedir fechamento.

## Persistência e interrupções

O arquivo próprio `remoto-consentimentos.xml` registra IDs, hash do pedido, prazos, etapa e decisão. Não registra nonce, desafio, nome do técnico, motivo livre, senhas ou tokens. O snapshot público também é uma lista fechada de metadados, sem esses campos.

O parser restringe tamanho, elementos, atributos, namespaces, datas e estados; não aceita DTD/entidades. Escrita usa arquivo temporário, substituição atômica, lock exclusivo e revisão para impedir sobrescrita por outra instância. Falha de gravação bloqueia a operação antes de disponibilizar a decisão ao transporte. O diretório deve herdar as proteções locais do monitor e não pode ser compartilhamento UNC ou reparse point.

Não há retomada após reinício. Registro não terminal coloca o broker em `interrupted`, bloqueando novos pedidos até confirmação de encerramento da mesma sessão central. Nonce não é recuperado do disco e consentimento não é reenviado. Pausa, console alterada/bloqueada, prazo expirado ou cancelamento invalidam o consentimento e pedem fechamento. Recuo de relógio maior que cinco segundos bloqueia o broker.

Os 128 registros máximos preservam pendências; apenas registros terminais com pedido expirado há mais de um dia podem sair na próxima gravação. O limite cheio bloqueia novos registros, sem apagar uma pendência para dar lugar a outro atendimento.

## Criptografia do piloto UltraVNC + Repeater + Guacamole

O [ticket oficial GUACAMOLE-1480](https://issues.apache.org/jira/browse/GUACAMOLE-1480) relata a ausência de suporte ao SecureVNCPlugin/DSM na biblioteca VNC usada por Guacamole. Não presumir que ativar esse plugin no UltraVNC garante interoperabilidade com guacd. TLS VNC nativo e DSM são mecanismos diferentes; qualquer alternativa precisa ser negociada e testada com versões exatas.

A autenticação VNC clássica é insuficiente como fronteira entre lojas. A proposta usa conexão de saída da loja por um túnel com **mTLS**, certificado/chave distintos por máquina e vínculo no gateway entre certificado, instalação, sessão autorizada e ID do Repeater. O servidor não pode aceitar um certificado válido de uma máquina para registrar o ID de outra. Guacd/Repeater ficam internos; VNC não será publicado na rede externa do caixa.

Stunnel documenta [autenticação mútua e verificação do servidor](https://www.stunnel.org/auth.html): validar a cadeia e o nome DNS (`verifyChain` e `checkHost`), exigir certificado de cliente no servidor, TLS mínimo 1.2 e CA de clientes dedicada. SNI não autentica o servidor. Cada chave local exige acesso restrito e renovação/revogação planejada. Não gerar certificados/chaves ou habilitar um túnel com estes documentos.

O [manual Guacamole](https://guacamole.apache.org/doc/gug/configuring-guacamole.html#vnc-repeater) descreve Repeater e reverse VNC, mas não comprova compatibilidade com todas as combinações de autenticação/plugin. O [UltraVNC](https://uvnc.com/home/) descreve a sessão Console/Current; o piloto deverá preservar essa sessão. Não trocar para RDP comum e assumir que será a mesma experiência do operador.

O diálogo do próprio UltraVNC é uma defesa adicional, sem aceitação por timeout. Não pode ser a única barreira: houve [relato de regressão no QueryAccept](https://github.com/ultravnc/UltraVNC/issues/289). A liberação do transporte pelo gateway depende do consentimento broker/operador e de lease temporário, independentemente do diálogo VNC.

## Preparação que permanece pendente antes de habilitar o remoto

1. Selecionar versões exatas de UltraVNC, túnel e bibliotecas do Guacamole; conferir assinatura, origem, hashes, licença e avisos/source das distribuições. Binários UltraVNC/stunnel não foram baixados nem incluídos. O bundle oficial Guacamole 1.6.0 foi obtido e teve o hash conferido apenas para o teste temporário de navegador; não integra as fontes ou o monitor.
2. Homologar no Windows o adaptador do Host preparado localmente: console interativa e desbloqueada, SID, sessão Windows e identidade desta execução. Validar o diálogo local já implementado com recusa padrão, técnico, motivo, capacidade, prazo e botão Encerrar visível.
3. Homologar HTTP/polling e recuperação de pendências preparados localmente, com a API desligada por padrão e habilitada apenas nas instalações do piloto. Não aceitar campos que virem comandos do Windows.
4. Homologar o acionamento temporário de túnel/UltraVNC preparado localmente, somente após consentimento e liberação central. O heartbeat deve comprovar o lease; perder gateway/renovação, pausar, encerrar o Host ou expirar deve fechar o transporte. Testar também processo broker morto/crash e revogação central.
5. Homologar o fluxo real de cada `PlatformProfile` pretendido, incluindo Windows 7 SP1 x86/x64, com CLR/.NET, TLS 1.2, UAC, console bloqueada/trocada, impressora/TEF, latência e antivírus. No Windows 7, confirmar o bloqueio antes de executar filhos quando o Host estiver em Job herdado; não usar breakaway. Sem desativar proteção ou criar exclusão geral.

O stunnel lista [Windows 7 de 32/64 bits](https://www.stunnel.org/platforms.html), mas suas [distribuições oficiais atuais](https://www.stunnel.org/downloads.html) oferecem somente win64. Para x86, é necessária uma build atual própria, assinada e homologada, com OpenSSL mantido e dependências compatíveis; ela ainda não foi produzida neste piloto. A elegibilidade Windows 7/x86 do código e a sintaxe PowerShell 2.0 do broker não comprovam execução das dependências. Não usar executáveis antigos nem desativar a validação de certificados para contornar a pendência. O ZIP 0.7.0 contém os iniciadores de instalação do núcleo e da extensão administrativa inativa. Ele não contém os binários de terceiros nem certificados/chaves; gerar o aplicativo não equivale a habilitar ou homologar a sessão remota.

O gateway preparado separadamente em `piloto-remoto/gateway` valida o cabeçalho de Repeater modo 2, com ID em bloco de 250 bytes sob mTLS e TTL próprio. Seus sinais de conexão comprovam somente transporte TCP. Nem `authorized` do broker nem `connected` do gateway comprovam tela visível, controle da sessão Windows, impressão corrigida ou atendimento concluído.

## Verificação offline

Executar `TestsMonitorRemoto.ps1` com PowerShell 5.1/7. Usa apenas diretórios temporários e adaptadores simulados. Não instala nem inicia dependências e não comprova comportamento real de Windows, WinForms, console/UAC, mTLS, VNC, Repeater ou Defender. Scripts preservam UTF-8 com BOM, CRLF e sintaxe compatível com Windows PowerShell 2.0 no módulo.
