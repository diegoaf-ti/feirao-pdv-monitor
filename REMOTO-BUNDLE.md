# Dependências do instalador remoto

O instalador completo pode carregar UltraVNC e stunnel sem transportar identidade de loja ou chave privada. O mesmo ZIP contém o monitor de inventário para todas as máquinas; o bundle remoto desta etapa contém apenas binários **x64**, para os perfis `win7-sp1-x64` e `win10plus-x64`. Windows de 32 bits continua sem bundle remoto aprovado. Aprovação de origem/assinatura não comprova interoperabilidade no caixa, Windows 7, Defender ou Panda.

## Conteúdo e origem

O lock `tools/remoto-bundle-lock.xml` fixa cada caminho, tamanho, hash SHA-256, arquitetura PE e certificado do editor. Ele acompanha o código administrativo e precisa coincidir byte a byte com `piloto-remoto/windows/bundle/remoto-bundle.xml`.

| Componente | Distribuição oficial fixada | Situação |
| --- | --- | --- |
| UltraVNC | [1.8.3.0 estável](https://uvnc.com/downloads/ultravnc/172-ultravnc-1-8-3-0.html), ZIP `11163a0b9b86321bf6403eb0cf84b81f7230ce32e6291377e1fe5beb987f7e4f` | WinVNC x64, ddengine64 e vnchooks com certificados originais distintos e pins próprios. Não inclui viewer, repeater, drivers ou plugin DSM. |
| stunnel | [5.82 estável](https://www.stunnel.org/downloads.html), instalador `722c1ad626919af2b0034666b4d19cc4795e925c32f60e8f3c59af4fb3ad2dfc` | stunnel, libcrypto e libssl x64 assinados pelo editor; inclui a distribuição assinada como prova de origem. |
| libssp | Runtime incluído naquele instalador stunnel | A DLL original não possui assinatura individual. A única exceção aceita é `bin/stunnel/libssp-0.dll`, SHA-256 `43ac5e338e3e05d2da19c48eef21f65b3e1833be0bc9c5735465f2935b371754`, com o contêiner original assinado presente e validado. Nenhuma outra DLL sem assinatura recebe essa exceção. |

O preparo valida a assinatura Authenticode do contêiner stunnel **antes de extrair**, sem executá-lo. Depois confere o conteúdo extraído, os hashes pinados e a assinatura de cada PE assinado. O instalador e o runtime repetem a validação. O contêiner em `sources/` não é executado pelo monitor.

Licenças e referências de código em `tools/remote-licenses/` acompanham o bundle em `licenses/`. Para redistribuição externa, manter acesso equivalente ao código correspondente e às condições de cada fornecedor junto ao download. Não redistribuir arquivos retirados de instalações anteriores.

## Gerar o ZIP com dependências

Executar no Windows de build, com Python 3.12+, OpenSSL de build disponível e 7-Zip instalado. O OpenSSL de build apenas confere as CAs públicas do pacote. Nenhum executável de terceiro do bundle é iniciado:

```powershell
python tools/preparar-bundle-remoto.py --output C:\Build\bundle-pdv
$version = (Get-Content -LiteralPath monitor-version.txt -Raw).Trim()
python tools/criar-pacote-instalacao.py --source . --output C:\Build\pacote-pdv --version $version --remote-bundle C:\Build\bundle-pdv
```

Usar a versão efetiva de `monitor-version.txt`; os diretórios de saída precisam ser novos. O workflow manual **Bundle remoto oficial para piloto** executa testes isolados, verifica Authenticode real no Windows e produz artefatos de conferência. Ele não publica release, não muda o feed de atualização, não instala remotamente e não cria certificados de computadores reais.

Sem `--remote-bundle`, o empacotador preserva o pacote sem executáveis de terceiros. Com essa opção, recusa sistema de build fora do Windows, assinatura/editor divergente, arquivo ausente ou extra, link, arquitetura errada, hash divergente e manifesto desconhecido. Não existe flag para ignorar assinatura nem recibo JSON capaz de substituí-la. Falha da cadeia/revogação Authenticode requer diagnóstico no Windows de build; não desativar essa validação.

## Validação pelo instalador/runtime

`tools/ValidarBundleRemoto.ps1` preserva sintaxe PowerShell 2.0 e pode ser carregado sem executar validações ou gravar arquivos:

```powershell
. C:\App\tools\ValidarBundleRemoto.ps1
$bundle = Assert-PdvRemoteBundle -BundleDirectory C:\App\piloto-remoto\windows\bundle -TrustedManifestPath C:\App\tools\remoto-bundle-lock.xml -ProfileId win10plus-x64
```

Retorno: `BundleId`, `Profiles`, `ManifestSha256`, `Files` e `RuntimeFiles`. Cada entrada de `Files` contém `RelativePath`, `Path`, `Sha256`, `SizeBytes`, `AuthPolicy` e `PublisherThumbprint`.

Na cópia já instalada, `-AllowRuntimeConfiguration` aceita adicionalmente **somente** `bin/ultravnc/ultravnc.ini` (até 64 KiB) e `bin/ultravnc/ultravnc.portable` vazio. A validação normal do pacote recusa esses arquivos. O instalador/runtime continua responsável por ACLs administrativas, correspondência do hash do INI ao perfil individual, vínculo da identidade e locks de leitura durante a sessão. O parâmetro não permite arquivo novo arbitrário, DLL, perfil alternativo ou comando central.

## Avaliação de OpenSSL embarcado

O stunnel 5.82 oficial foi compilado com OpenSSL **3.5.8**. A versão LTS corrigida vigente nesta análise é **3.5.9**. Não usar a afirmação “sem vulnerabilidades” para esse bundle. A avaliação do [aviso primário de 29/09/2026](https://openssl-library.org/news/secadv/20260929.txt) considera o fluxo efetivo do piloto: cliente TCP/TLS, certificado cliente RSA individual, CA e nome do servidor fixados, processo filho por sessão e sem DTLS, QUIC, CMP ou SM2.

| Grupo | Aplicabilidade ao fluxo |
| --- | --- |
| CVE-2026-84782 (High) e CVE-2026-75806 | DTLS; o túnel utiliza TCP/TLS, portanto o vetor específico não é exercitado. |
| CVE-2026-84783 | Afeta OpenSSL 4.0; o aviso exclui a série 3.5. |
| CVE-2026-35191, 42772, 54873, 75804 e 84784 | QUIC; não utilizado. |
| CVE-2026-54872, 54875 e 77696 | Assinatura ECDSA genérica/SM2 e, em parte, plataformas ARM/RISC-V; a identidade cliente é RSA em x64. |
| CVE-2026-72897 | Troca de contexto durante handshake em servidor TLS; este processo atua somente como cliente. |
| CVE-2026-75805 | Cliente CMP usando revogação por CSR; o monitor usa a API própria de inscrição, sem CMP. |
| **CVE-2026-35189 (Low)** | **Risco residual aplicável:** parser de extensões CRLDP de certificado do peer pode consumir muita memória durante handshake. CA fixada não elimina processamento anterior à decisão de confiança. Processo efêmero, limites do Job e uma sessão por instalação reduzem o impacto; não são correção da biblioteca. |

Por decisão de implementação, a distribuição oficial permanece candidata ao **piloto assistido**, com esse risco residual registrado. Preferir promover stunnel 5.82 recompilado com OpenSSL 3.5.9, após assinatura e ensaio; não trocar DLLs entre distribuições nem usar versão antiga de stunnel x86 para preencher a ausência. stunnel 5.83b2 é beta; não foi adotado como se fosse versão estável.

## Caminho de build x86/x64 com biblioteca corrigida

`tools/CompilarStunnelMsvc.ps1` e o workflow manual **Candidato stunnel MSVC e OpenSSL LTS** preparam stunnel 5.82 + OpenSSL 3.5.9 estático, sem libssp e sem OpenSSL DLL externo. Os tarballs têm hashes fixos. A receita seleciona MSVC v142 e SDK 10.0.19041, força alvo Win7/PE 6.01, confere DLLs importadas e rejeita funções conhecidas que exigem Windows mais recente. Toolchain ausente/divergente recusa a compilação; não há troca silenciosa de compilador. A proveniência registra fontes, receita, arquitetura, imports e hash **anterior à assinatura**.

Isso é uma receita repetível, ainda não comprovada como build bit a bit reproduzível nem homologada no Windows 7. O artefato produzido recebe `NAO-DISTRIBUIR` e `distributable=false`. Não há certificado de assinatura de código da empresa neste repositório. Antes de promover:

1. Compilar em runner controlado e arquivar fonte exata, toolchain e relatório.
2. Ensaiar TLS/identidade, interoperabilidade, Win7 SP1 x86/x64 e Win10/11, além de Defender/Panda, sem exclusões de antivírus.
3. Assinar o EXE final com certificado de código confiável e timestamp; a chave de assinatura permanece no cofre/HSM, fora de repositório, ZIP e logs.
4. Conferir Authenticode real, gerar novos hashes do arquivo **assinado**, atualizar lock e revisão de dependências, adicionar os perfis x86 somente então e produzir novo pacote.

Assinatura não garante ausência de bloqueio do Defender ou SmartScreen. O produto deve conservar identificação, instalação/desinstalação visíveis, confirmação por sessão e ausência de listener VNC na rede. Não desativar proteções, usar UPX/obfuscação para escapar da detecção ou instalar sessão sem consentimento.
