# Certificado exclusivo instalado pelo cliente

Um pacote atende todas as lojas. Embute apenas as CAs públicas e o destino HTTPS em `inscricao-confianca.xml`, sob controle administrativo. O código temporário identifica a instalação cadastrada no Conecta; não se deduz loja/caixa pelo nome do Windows. Nenhuma chave compartilhada nem chave privada de CA integra o pacote.

A preparação administrativa copia os componentes para `%ProgramData%\Feirao\PdvMonitorRemoto\app`. Execute `AtivarCertificadoRemoto.cmd` do pacote conferido como administrador. Seu bootstrap valida proprietario, permissoes, ausencia de redirecionamentos e arquivos vinculados, e segura os fontes instalados com bloqueio de escrita/exclusao antes de executar qualquer codigo de ProgramData. Se uma pasta foi precriada por usuario comum ou a preparacao falhou, a ativacao e bloqueada sem executar a CLI ali encontrada. Depois informe informe o código de uso único gerado no Conecta e a conta Windows que roda o monitor. O código é solicitado como senha, sem argumento ou log. O SID dessa conta limita a leitura da chave; somente SYSTEM/Administradores podem alterar os arquivos. Não se usa o token DPAPI da telemetria.

A ativação gera RSA 2048 local via CSP RSA_AES, cria CSR PKCS#10/SHA256 e envia apenas CSR/código/requestId ao destino HTTPS fixo. A chave PEM local atende ao stunnel e fica fora dos dados/exportações do monitor. O módulo não faz importação no repositório Raiz Confiável do Windows, não usa OpenSSL no cliente, não modifica Schannel/Registro e não ignora validação TLS.

A resposta é XML fechado. O cliente confere pedido/agente, host/porta fixados no pacote, validade, SHA256 DER do certificado, chave pública vinculada ao CSR, CN `pdv-<agentId>`, uso de assinatura e EKU clientAuth. Aceita folha direta ou folha + um intermediário CA:true/pathlen:0, assinados até a raiz pública fixada; nunca baixa AIA/CRL ou confia em uma CA recebida arbitrariamente. Raiz com pathlen:0 não pode emitir intermediário.

Tentativas interrompidas preservam a chave/CSR/requestId para reenvio idempotente. Estado incompleto/incoerente não é apagado nem substituído automaticamente. Uma resposta não habilita o perfil remoto nem aprova binários/SO: certificado válido, componentes assinados aprovados e consentimento local continuam sendo condições independentes.

Requer Windows PowerShell com CLR4 e .NET Framework 4.6.2 ou superior; Windows 7 exige SP1 e ambiente TLS/certificados atualizado. Sintaxe dos scripts é compatível com PowerShell 2.0, mas executar PowerShell 2 no CLR2 não é suficiente para a criptografia deste módulo. Não há promessa de homologação Windows real sem testes x86/x64.

Teste offline em macOS/Linux, com PowerShell 7, Python 3 e OpenSSL 3 somente para autoridades efêmeras de teste:

```text
pwsh -NoProfile -File ./TestsMonitorInscricaoRemota.ps1
```

O teste não lê a PKI real nem realiza inscrição/rede/instalação Windows. Testes de ACL, CSP, elevação, TLS real, Windows 7/10 e stunnel ainda devem ser realizados em uma máquina de homologação autorizada. Nenhuma publicação é feita por estes arquivos.
