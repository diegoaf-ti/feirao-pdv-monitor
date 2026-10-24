# Monitor 0.8 — instalação do suporte remoto e renovação

O pacote **com remoto x64** reúne monitor, UltraVNC, stunnel, certificados públicos e fontes legíveis. O pacote leve não contém os executáveis remotos. Nenhum ZIP contém chaves privadas, senha VNC compartilhada ou código de uma loja.

## Instalação inicial

1. Fora de venda/pagamento, encerre o monitor pelo ícone e extraia todo o ZIP com remoto. Entre com o usuário Windows que utiliza o monitor.
2. Execute `Instalar.cmd`. O monitor é instalado para esse usuário, preservando dados. Escolha preparar suporte remoto e aceite a solicitação única de administrador do Windows.
3. Gere o código da instalação correta no Conecta e informe-o no instalador. O código dura quinze minutos. A instalação gera a chave no computador e guarda o certificado e o perfil em uma pasta administrativa protegida.
4. O instalador confere assinaturas, hashes, arquitetura e arquivos de todo o bundle. O perfil fica desativado até a tarefa de renovação ser registrada com sucesso.
5. Confira a validade e as permissões no Conecta e faça o primeiro atendimento acompanhado. Cada sessão exige técnico autorizado, confirmação visível do operador e prazo limitado. Instalar não autoriza uma sessão automaticamente.

Não execute a instalação comum usando outra conta administrativa: a telemetria usa a identidade do usuário original. A elevação separada recebe somente o SID desse usuário, sem senha ou código na linha de comando.

## Renovação

A tarefa `Feirao-PdvMonitor-RenovarCertificado` executa como SYSTEM um script fixo, em diretório que usuários comuns não podem alterar. Não executa comandos fornecidos pelo servidor. Verifica a validade localmente por hora; somente nos últimos trinta dias solicita renovação pela API HTTPS. Os horários têm distribuição aleatória. Não há heartbeat adicional por essa verificação.

A API exige desafio de cinco minutos e prova RSA-SHA256 da chave atual. A nova chave é gerada no computador. O servidor prepara o certificado sem substituir o atual; a confirmação exige prova da chave nova. Pedido e etapas são persistidos. Resposta perdida, reinício ou falha de gravação preservam a mesma intenção e as duas gerações. Sessões e renovação compartilham um lock entre SYSTEM e o usuário Windows, sem encerrar atendimento para trocar arquivos.

O certificado de dispositivo tem validade configurável no emissor, até noventa dias. Certificado vencido, revogado ou autoridade vencida não são aceitos silenciosamente. Recuperação requer procedimento administrativo revisado; não basta copiar outra identidade ou repetir o código de outra máquina. As autoridades públicas e o certificado HTTPS do domínio têm ciclo próprio de manutenção no servidor.

## Limites e retomada

Os perfis com bundle são Windows 7 SP1 x64 e Windows 10/11 x64, exigindo .NET Framework 4.6.2 ou superior e PowerShell sob CLR4; recomenda-se WMF5.1/.NET4.8 no Windows7. O ensaio real de TLS, ACLs, assinatura, Defender, UAC, portable INI e sessão ainda é obrigatório na loja49. A existência de um perfil no código não equivale a homologação física.

Windows x86 não possui bundle remoto aprovado nesta entrega. O inventário e diagnóstico do monitor continuam independentes. O pipeline de compilação x86 gera somente artefatos NÃO-DISTRIBUIR até revisão, assinatura e homologação. Consulte `REMOTO-BUNDLE.md` para a proveniência e avaliação das bibliotecas.

Repetir uma instalação interrompida só retoma arquivos da mesma versão e identidades locais conferidas. Arquivos desconhecidos e extensões administrativas antigas são preservados e bloqueiam atualização automática; é necessária atualização administrativa revisada. Uma instalação nova do monitor sobre a antiga não substitui silenciosamente a extensão protegida.

No Conecta, validade ou certificado instalado não significam sessão aberta. Revogar a identidade é permanente; encerramento de atendimento é outra ação. Resultado pendente de gateway não deve ser considerado bloqueio remoto confirmado.

## Servidor

Aplicar `database/ddl/create_pdv_monitor_remote_identity.sql` na base correta antes de atualizar a API. Publicar o gateway e a API compatíveis, preservando emissor, journals, chaves e configuração existentes. Nenhuma porta pública adicional é necessária: renovação passa pelo HTTPS443 e o controle API/gateway continua mTLS interno. O acesso remoto de dispositivo continua na porta5443 já autorizada no HML.

O feed de atualização automática da frota permanece inalterado. A primeira instalação com remoto é manual e acompanhada. Nenhuma máquina ou política é ativada só por gerar/publicar o pacote.

## Troca da identificação central com fila pendente

Se o cadastro informar `PendingIdentityChange`, confirme primeiro a loja, o caixa e a instalação corretos. A troca continua bloqueada por padrão. Ao confirmar expressamente o arquivamento, o monitor move a fila anterior e seus inventários/checkpoints para `identidades-anteriores/<GUID>/`, preservando os bytes, EventIds, configuração e credencial DPAPI do usuário. Esses registros não são enviados como se pertencessem ao novo agente, não recebem confirmação fictícia e não entram na rotação de logs de trinta dias. O retorno `ArquivoPreservado` informa o caminho local para consulta pela manutenção; a exportação comum de diagnóstico não inclui essa credencial.

A troca grava snapshots e um journal durável antes de mover arquivos. Se houver interrupção, a inicialização finaliza a troca somente quando configuração e credencial novas correspondem à intenção gravada; caso contrário, restaura o estado anterior. Colisão com conteúdo diferente mantém os arquivos e bloqueia o envio para análise do suporte. Não apague `identity-switch.xml` ou a pasta de histórico para contornar esse bloqueio. O inventário da identidade nova recebe sua própria confirmação.
