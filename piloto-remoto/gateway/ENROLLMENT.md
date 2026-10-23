# Provisionamento de certificados por computador — candidato local

Nenhuma implantação acompanha este código. O provisionamento permanece desligado no exemplo; não lê nem cria certificados reais durante os testes.

O mesmo instalador pode atender todas as lojas. Ele carrega apenas autoridades públicas confiáveis. A chave privada de cada computador é criada naquele Windows; um CSR público solicita sua identidade individual. O backend troca o código de ativação de uso único, emitido por um administrador, pelo certificado. O gateway não aceita códigos nem pedidos de cadastro na porta pública dos dispositivos.

## Controle interno

Todas as operações abaixo passam pelo HTTPS interno existente, com a CA de controle e o fingerprint exato do certificado cliente da API. Certificados dos caixas não autorizam esse controle.

`POST /v1/devices/enrollments` recebe exatamente:

```json
{
  "requestId": "UUID da solicitação, estável para repetição",
  "agentId": "UUID da instalação aprovada",
  "repeaterId": "identificador decimal sem zero inicial",
  "csrPem": "CSR público com CN=pdv-<agentId>",
  "previousCertificateSha256": null
}
```

O backend deve autorizar o cadastro daquele agente e manter o acesso remoto desabilitado até a liberação administrativa. O endpoint não cria lease, não aceita consentimento e não inicia conexão ou sessão remota. CSR tem limite de 4096 bytes, assinatura forte comprovada e chave RSA de 2048 a 4096 bits e assinatura SHA256/RSA; subject precisa identificar exatamente o agente autorizado. As extensões solicitadas pelo CSR são ignoradas. A folha recebe somente clientAuth, CA:FALSE, digitalSignature; o CN é vinculado ao agente.

A resposta possui exatamente `requestId`, `agentId`, `repeaterId`, `certificatePem`, `certificateSha256` e `expiresAt`. `certificatePem` contém a folha seguida por um intermediário (não inclui a raiz); SHA256 é o fingerprint da folha. A chave privada do cliente e a senha VNC não integram a resposta. A senha VNC é criada no gateway e permanece no estado privado, disponível somente pelo fluxo de sessão já autorizado.

Repetições com o mesmo requestId e conteúdo devolvem o mesmo certificado, inclusive após reinício. Alteração do conteúdo gera 409. Depois de uma rotação, solicitações antigas não reinstalam o certificado anterior. O módulo aceita rotação pelo controle interno quando `previousCertificateSha256` corresponde ao atual, sem lease ativa. A primeira API do piloto pode disponibilizar apenas o cadastro inicial; renovação automática pelo cliente precisa de fluxo próprio autorizado no backend.

`DELETE /v1/devices/<agentId>` revoga o dispositivo e devolve `{ "agentId": "...", "revoked": true }`. Encerra leases existentes e remove o fingerprint aceito. A revogação persiste, é idempotente e impede novo cadastro/replay daquele agente. Dispositivo nunca cadastrado retorna 404. Não há endpoint para apagar tombstones ou reabilitar automaticamente um dispositivo revogado.

## Emissor e estado

Ativar exige `enrollment.enabled=true` e `enrollment.issuer.enabled=true`, com configuração local privada. `caCertificateFile` contém um único certificado intermediário RSA, CA:true/pathlen:0, assinado pela DeviceCA raiz com pathlen mínimo 1 já confiável na porta dos dispositivos. `caPrivateKeyFile` aponta somente para a chave desse intermediário, gerada no próprio servidor. A chave da raiz continua offline e não é transferida para o servidor. O emissor recusa usar a própria raiz para emitir folhas diretamente.

O emissor exige OpenSSL 3 disponível por caminho absoluto, validade configurável de 1 a 90 dias e validade restante suficiente de toda a cadeia. Não usa shell, não copia extensões do CSR e não mantém CSR após emitir. Diretórios/arquivos privados devem pertencer ao usuário do gateway, com 0700/0600.

`enrollment.journal` é separado de leases.json e contém vínculos, certificados públicos, tombstones, senhas VNC e idempotência. Nunca contém chaves privadas de clientes. Inicializar somente com gateway parado, em diretório privado, por `initializeEnrollmentState(caminhoAbsoluto, '--gateway-stopped')`; nunca sobrescreve estado existente. Ambos os journals têm exclusão de escritor. Gravações usam arquivo temporário privado, fsync, rename e fsync de diretório. Falha de persistência ou instalação de vínculo derruba as sessões e mantém o lock para manutenção; o startup não recupera locks automaticamente.

Limites deste piloto: 1024 dispositivos, 4096 solicitações persistidas e arquivo total de no máximo 8 MiB; ao atingir limite, falha fechada. Aumentar/arquivar exige manutenção planejada preservando revogações e idempotência.

## Verificação local

```text
node --test test/*.test.js
```

No macOS, testes selecionam OpenSSL do PATH; `OPENSSL=/caminho/absoluto/openssl` pode selecionar OpenSSL 3 explicitamente. Todos os certificados são sintéticos, em diretórios temporários. Os testes com TLS exigem permissão para ouvir em 127.0.0.1. Não usam banco, servidor publicado ou certificados reais.
