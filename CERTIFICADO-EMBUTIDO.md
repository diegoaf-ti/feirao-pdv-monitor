# Certificado no instalador único — versão 0.7.1

O instalador leva as autoridades **públicas** aprovadas para reconhecer o servidor
e conferir os certificados emitidos. O mesmo pacote atende à loja 49 e às demais;
não existe número de loja, caixa ou identidade privada fixado nele.

## Instalação prevista

1. Instalar o monitor e executar `piloto-remoto/windows/PrepararRemoto.cmd` como
   administrador, conforme o guia do aplicativo.
2. No Conecta, abrir o computador cadastrado e gerar seu código de instalação.
3. Executar `piloto-remoto/windows/AtivarCertificadoRemoto.cmd` do pacote conferido,
   como administrador. Informar o código e a conta Windows que executa o monitor.
4. O instalador cria a chave somente naquele computador, solicita o certificado,
   confere identidade/cadeia/destino e guarda os arquivos em uma pasta protegida.

Não é preciso importar manualmente certificados no Windows. O código dura quinze
minutos e identifica o AgentId escolhido; o nome do Windows não determina o caixa.
O bootstrap valida os arquivos administrativos antes de executá-los. Código não
vai na linha de comando, em URL, nos logs ou no histórico funcional.

Se a resposta se perder, repetir a ativação preserva a mesma chave/solicitação.
Após expiração do código, o administrador pode gerar um código de recuperação
para o mesmo pedido. Isso não permite cadastrar outra chave ou trocar a identidade
emitida. Arquivos privados parciais não são apagados automaticamente.

## Limites de ativação

Este fluxo instala a identidade, sem habilitar uma sessão, aprovar executáveis ou
criar autorização para técnicos. Os componentes UltraVNC/stunnel, seu perfil
administrativo e o consentimento do operador continuam necessários. A senha VNC
permanece fora deste cadastro; o vínculo do perfil portable requer provisionamento
administrativo próprio. Ações existentes de encerramento no Conecta encerram
sessões; revogação definitiva de certificado só existe no controle interno do
gateway nesta etapa. Renovação de identidade não é automática nesta versão.

O Windows 7 exige SP1, CLR4/.NET4.6.2 ou superior e os demais pré-requisitos já
documentados. Sintaxe PowerShell2 não significa execução sob CLR2. A arquitetura
e os componentes assinados ainda devem ser ensaiados em cada perfil Windows.

## Distribuição e preparação do ambiente

O ZIP `Monitor-PDV-0.7.1-Windows.zip` é uma instalação manual para piloto acompanhado. Inclui somente certificados públicos; nenhuma identidade privada ou código de ativação está embutido. O pacote 0.7.0 anteriormente entregue permanece intacto. Não enviar o novo pacote ao feed das versões 0.6 ou anteriores.

A emissão usa uma raiz de dispositivos com pathlen1 e uma intermediária pathlen0 cuja chave é mantida no servidor. A hierarquia anterior pathlen0 não admite essa intermediária. O ambiente correspondente deve estar configurado com as rotas do painel/API, tabelas e emissor, além da confiança correta na porta dos dispositivos. O ZIP não aplica essas mudanças no servidor ou banco e não garante que um ambiente esteja pronto só por estar disponível para download.

A nova raiz pública está em `piloto-remoto/windows/identity-device-ca.crt`, e sua
impressão SHA256 em `inscricao-confianca.xml`. A CA de servidor existente permanece
em `identity-server-ca.crt`. Nunca embutir a chave da raiz, do emissor, da API ou
uma chave de cliente neste pacote. O empacotador recusa material privado nesses
campos, raiz sem capacidade de intermediária e alterações dos pins/destinos.

Antes do primeiro uso: conferir a publicação da API/painel e do emissor no ambiente,
preparar os componentes remotos aprovados e realizar um teste assistido na loja49.
Testes no macOS e testes isolados no CI não homologam CSP, ACLs, elevação,
TLS, antivírus ou uma sessão remota real no Windows.
