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

Repetições com o mesmo requestId e conteúdo devolvem o mesmo certificado, inclusive após reinício. Alteração do conteúdo gera 409. Depois de uma rotação, solicitações antigas não reinstalam o certificado anterior. O cadastro legado continua aceitando rotação pelo controle interno quando `previousCertificateSha256` corresponde ao atual, sem lease ativa. Para renovação automática, usar exclusivamente o protocolo de duas fases abaixo: o endpoint legado substitui o vínculo imediatamente e não protege contra perda da resposta no cliente.

`DELETE /v1/devices/<agentId>` revoga o dispositivo e devolve `{ "agentId": "...", "revoked": true }`. Encerra leases existentes e remove o fingerprint aceito. A revogação persiste, é idempotente e impede novo cadastro/replay daquele agente. Dispositivo nunca cadastrado retorna 404. Não há endpoint para apagar tombstones ou reabilitar automaticamente um dispositivo revogado.

## Renovação automática em duas fases

Os endpoints continuam somente no controle mTLS interno. A API pública deve exigir a credencial da instalação, a política administrativa e uma prova RSA/SHA256 com a chave privada do certificado atual, vinculada a desafio curto, operação, requestId, agente, repetidor, fingerprint e hash do novo CSR. O gateway confia nessa autorização da API pinada; ele não substitui a validação pública da assinatura/desafio. Nunca encaminhar chaves privadas. A API deve persistir a intenção e seu `requestedAt` antes de chamar o gateway, repetindo exatamente o mesmo conteúdo quando a resposta for incerta.

`POST /v1/devices/renewals` prepara uma nova folha sem substituir o fingerprint aceito. Recebe exatamente:

```json
{
  "requestId": "UUID estável da intenção",
  "agentId": "UUID da instalação",
  "repeaterId": "identificador decimal",
  "csrPem": "CSR público da nova chave",
  "previousCertificateSha256": "fingerprint SHA256 atual",
  "requestedAt": "2026-10-24T10:00:00.000Z"
}
```

O timestamp deve ser ISO UTC canônico emitido pela API/desafio; para preparar uma intenção inédita, pode ter no máximo cinco minutos e no máximo 30 segundos no futuro. Certificado atual vencido ou revogado é recusado. Não pode existir lease pendente, pronta ou conectada, nem outra proposta ainda válida do mesmo agente. A resposta contém exatamente `requestId`, `agentId`, `repeaterId`, `previousCertificateSha256`, `certificatePem`, `certificateSha256`, `expiresAt`, `preparedUntil` e `state`. O estado inicial é `prepared` e `preparedUntil` fica 24 horas após a preparação; o certificado atual continua válido e aceito. Senha VNC, chave privada e códigos não integram a resposta.

Prepare é persistido antes da resposta. Retry idêntico recupera exatamente o mesmo certificado, inclusive após reinício ou depois do prazo inicial de cinco minutos, enquanto a proposta estiver válida. `RenewalConflict` (409) indica reutilização divergente de requestId. `RenewalAlreadyPending` (409) indica outra proposta ainda válida. O cliente deve validar a cadeia e a correspondência com sua nova chave, preparar arquivos próprios protegidos e manter a identidade antiga recuperável antes de confirmar. Não trocar o stunnel em uma sessão ativa.

`POST /v1/devices/renewals/<requestId>/commit` recebe exatamente:

```json
{
  "agentId": "UUID da instalação",
  "repeaterId": "identificador decimal",
  "previousCertificateSha256": "fingerprint antigo",
  "certificateSha256": "fingerprint da proposta persistida"
}
```

Commit exige o mesmo vínculo atual, a proposta válida, ambas as folhas não vencidas e ausência de lease ativa. Persiste a nova geração antes de instalar o vínculo em memória. Somente então responde com o mesmo objeto do prepare e `state: committed`. A senha VNC permanece a mesma. Depois desse ponto o fingerprint antigo é recusado; não há intervalo de aceitação das duas identidades. Se a resposta se perder, repetir commit ou prepare retorna `committed` sem emitir outro certificado nem instalar a geração antiga. O resultado confirmado é preservado enquanto seu fingerprint for atual, mesmo após `preparedUntil`. Falha de persistência ou instalação fecha o gateway e mantém lock para manutenção; não há rollback silencioso.

`POST /v1/devices/renewals/<requestId>/status` recebe o mesmo corpo do commit e retorna o estado durável, sem mudar identidade ou criar sessão. `certificateSha256` pode ser `null` somente em status e abort quando o emissor preparou, mas a resposta se perdeu. Agente, repetidor e fingerprint anterior continuam obrigatórios e conferidos.

`POST /v1/devices/renewals/<requestId>/abort` recebe esse mesmo corpo e responde `{ requestId, agentId, state: "aborted" }`. É idempotente enquanto o registro existir. Uma proposta expirada também pode ser cancelada, mantendo a identidade antiga; uma já confirmada retorna `RenewalAlreadyCommitted` (409), nunca desfaz a rotação. Proposta expirada retorna `RenewalExpired` (409) em prepare/commit/status; nunca reemite no mesmo requestId. Cancelar e criar uma nova intenção/desafio com outro requestId permite tentar novamente se o certificado atual ainda estiver válido. Depois de compactado, o registro retorna `RenewalNotFound` (404); a API só deve liberar a intenção local pendente após conferir que o vínculo atual ainda é o antigo. Certificado vencido exige nova ativação pela manutenção.

Revogar pelo endpoint legado fecha todas as leases, persiste o tombstone e impede prepare, status, commit, cancelamento e perfil, inclusive em propostas cuja resposta já foi entregue. Nunca reabilita automaticamente um agente revogado.

## Perfil para instalação

`POST /v1/devices/profiles` recebe exatamente `{ agentId, repeaterId, certificateSha256 }`, exigindo o fingerprint atual, não revogado e não vencido. Responde exatamente `{ agentId, repeaterId, certificateSha256, vncPassword, expiresAt }`, com `Cache-Control: no-store`. `vncPassword` é segredo individual do VNC, entregue somente à API mTLS pinada. A API pública também deve exigir desafio assinado com a identidade atual e a política da instalação, nunca logar o perfil e entregá-lo apenas ao computador autorizado. O cliente deve protegê-lo em disco e excluí-lo da exportação de diagnóstico.

O perfil não cria lease nem autoriza um atendimento. Regras de usuário/permissão, prazo e consentimento local por sessão permanecem obrigatórias. A senha não muda na renovação; o cliente pode obter o perfil atual antes de preparar a nova chave. Perfil da proposta ainda não confirmada é recusado. O gateway não distribui nem instala executáveis UltraVNC/stunnel; o instalador cliente precisa validar os pacotes aprovados e preparar a configuração local sem abrir listener de acesso direto.

## Emissor e estado

Ativar exige `enrollment.enabled=true` e `enrollment.issuer.enabled=true`, com configuração local privada. `caCertificateFile` contém um único certificado intermediário RSA, CA:true/pathlen:0, assinado pela DeviceCA raiz com pathlen mínimo 1 já confiável na porta dos dispositivos. `caPrivateKeyFile` aponta somente para a chave desse intermediário, gerada no próprio servidor. A chave da raiz continua offline e não é transferida para o servidor. O emissor recusa usar a própria raiz para emitir folhas diretamente.

O emissor exige OpenSSL 3 disponível por caminho absoluto, validade configurável de 1 a 90 dias e validade restante suficiente de toda a cadeia. Não usa shell, não copia extensões do CSR e não mantém CSR após emitir. Diretórios/arquivos privados devem pertencer ao usuário do gateway, com 0700/0600.

`enrollment.journal` é separado de leases.json e contém vínculos, certificados públicos, tombstones, senhas VNC e idempotência. Nunca contém chaves privadas de clientes. Inicializar somente com gateway parado, em diretório privado, por `initializeEnrollmentState(caminhoAbsoluto, '--gateway-stopped')`; nunca sobrescreve estado existente. Ambos os journals têm exclusão de escritor. Gravações usam arquivo temporário privado, fsync, rename e fsync de diretório. Falha de persistência ou instalação de vínculo derruba as sessões e mantém o lock para manutenção; o startup não recupera locks automaticamente.

Limites: 1024 dispositivos (incluindo revogados), 4096 cadastros legados na leitura de estado antigo, 4096 renovações e arquivo total de no máximo 32 MiB. Atingir limite falha fechado. O journal v1 é aceito e convertido em memória; somente uma próxima mutação durável escreve v2, que inclui `renewals`. A migração não altera o journal de leases, as portas já consumidas ou os tombstones.

Cada gravação compacta gerações: conserva até os dois últimos resultados de cadastro por computador; conserva o resultado da renovação confirmada enquanto seu fingerprint for o atual; conserva propostas e cancelamentos ainda dentro das 24 horas e vinculados ao certificado atual. Revogações nunca são apagadas. Para 1000 computadores renovando a cada 90 dias, não há acúmulo de um novo resultado por geração. O teste de compactação cobre mil identidades e dez gerações sintéticas; isso não comprova capacidade de carga do servidor. Cancelamentos repetidos dentro de 24 horas continuam limitados a 4096 registros; abuso ou falha de integração pode alcançar esse limite e exigir manutenção.

A remoção de resultados antigos não permite reinstalar credenciais: propostas inéditas exigem timestamp curto e CAS do fingerprint atual. Repetição com o timestamp antigo, depois de compactada, falha; gerações antigas também falham no CAS. Tombstones impedem todos os replays de agentes revogados.

## Verificação local

```text
node --test test/*.test.js
```

No macOS, testes selecionam OpenSSL do PATH; `OPENSSL=/caminho/absoluto/openssl` pode selecionar OpenSSL 3 explicitamente. Todos os certificados são sintéticos, em diretórios temporários. Os testes com TLS exigem permissão para ouvir em 127.0.0.1. Não usam banco, servidor publicado ou certificados reais.
