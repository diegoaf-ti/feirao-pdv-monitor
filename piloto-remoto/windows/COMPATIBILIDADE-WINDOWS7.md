# Compatibilidade do acesso remoto com Windows 7

O candidato 0.7.0 tem geração local autorizada em ZIP, preparado no macOS, sem execução em Windows, instalação nas lojas, publicação do Conecta/API ou alteração de banco. O código admite Windows 7 SP1 de 32 e 64 bits. **Não houve ensaio em Windows real e ainda não existe bundle atual de stunnel x86 construído, assinado e homologado para este piloto.** A elegibilidade no código permite preparar esse ensaio; não comprova disponibilidade operacional.

## Perfis admitidos no código

| `PlatformProfile` | Sistema de estação de trabalho | Arquitetura nativa e processo do monitor | Executáveis externos |
| --- | --- | --- | --- |
| `win7-sp1-x86` | Windows 7 SP1, versão `6.1.7601` | x86 / 32 bits | PE x86 |
| `win7-sp1-x64` | Windows 7 SP1, versão `6.1.7601` | x64 / 64 bits | PE x64 |
| `win10plus-x86` | Windows 10, versão `10.0`, build >= `10240` | x86 / 32 bits | PE x86 |
| `win10plus-x64` | Windows 10/11, versão `10.0`, build >= `10240` | x64 / 64 bits | PE x64 |

O perfil vem de `RtlGetVersion` e da arquitetura nativa, sem confiar apenas no nome amigável do sistema. Somente `ProductType=1` é admitido. Windows 7 sem SP1, Vista, 8/8.1, Windows Server, ARM e processo de arquitetura diferente da nativa ficam bloqueados. Windows Server 2008 R2 não é admitido por compartilhar a versão `6.1` com Windows 7. Em Windows x64, o monitor remoto precisa executar no PowerShell nativo de 64 bits; o processo de 32 bits sob WOW64 não satisfaz esse perfil.

CLR 4 e .NET Framework **4.6.2 ou posterior**, com `Release >= 394802`, são requisitos do adaptador remoto. Recomenda-se **WMF/Windows PowerShell 5.1 com .NET Framework 4.8** no Windows 7 SP1. A sintaxe PowerShell 2 do monitor não significa que o CLR 2 original do Windows 7 atenda ao acesso remoto. Esses requisitos não autorizam instalar ou atualizar o ambiente automaticamente.

A Microsoft lista .NET Framework 4.8 para [Windows 7 SP1 x86/x64](https://learn.microsoft.com/en-us/dotnet/framework/get-started/system-requirements). O [WMF 5.1](https://devblogs.microsoft.com/powershell/windows-management-framework-wmf-5-1-released/) tem instruções próprias para Windows 7 e requer .NET a partir de 4.5.2; adotar o perfil recomendado não dispensa revisar as dependências de outros programas do caixa.

## Configuração e aprovação por perfil

A primeira migração de 0.6 para o núcleo 0.7.0 é manual, com o monitor fechado e o mesmo usuário, executando `Instalar.cmd`; o núcleo passa a ter 22 arquivos. O atualizador antigo não aceita esse novo conjunto. Veja [GUIA-INSTALACAO-0.7.md](../../GUIA-INSTALACAO-0.7.md).

A preparação administrativa é separada: `PrepararRemoto.cmd` precisa ser executado explicitamente como administrador e copia apenas código/modelos inativos para `%PROGRAMDATA%\Feirao\PdvMonitorRemoto\app`. Uma instalação existente exige revisão e não é sobrescrita. Não são distribuídos PKI, binários de terceiros ou perfil ativo, e o atualizador do usuário não altera a extensão. O módulo Windows só é importado dessa raiz fixa, após conferir proprietário/ACLs, ancestrais e ausência de reparse points/hard links; não é importado de `LOCALAPPDATA`.

O perfil ativo, quando provisionado separadamente pelo administrador, fica em `app\piloto-remoto\windows\remoto-piloto.xml`. Esse XML usa schema `2`, com campos fechados e `PlatformProfile` exatamente igual a um dos valores da tabela. O arquivo schema `1` anterior é recusado, sem conversão automática. Isso é independente do XML de lease `PdvRemoteLease schemaVersion="1"` da API e dos journals, cujas versões não mudam por causa deste ajuste.

Cada configuração aprova um conjunto específico de sistema, arquitetura, hashes SHA256, assinatura Authenticode, certificado do editor e INI portable. `ProfileApproved` continua falso no modelo e só deve ser habilitado após a revisão daquele conjunto. Mudar apenas o nome do perfil não converte um bundle de x64 para x86 nem transfere a homologação entre sistemas. Os binários precisam corresponder à arquitetura nativa, ter o hash aprovado e assinatura válida do editor esperado. As ACLs administrativas, o vínculo com o agente e os certificados individuais continuam obrigatórios.

O UltraVNC atual declara [Windows 7 como sistema mínimo e oferece x86/x64](https://uvnc.com/downloads/ultravnc/172-ultravnc-1-8-3-0.html). A versão exata do ensaio ainda precisa comprovar leitura do INI portable dedicado, autenticação reversa, ausência de listeners externos e interoperabilidade com o gateway/Guacamole. Não reutilizar a instalação de acesso remoto já existente na máquina.

O stunnel lista [Windows 7 em edições 32 e 64 bits](https://www.stunnel.org/platforms.html), mas suas [distribuições oficiais atuais](https://www.stunnel.org/downloads.html) oferecem somente instalador win64. O [build Windows no código do stunnel](https://github.com/mtrojnar/stunnel/blob/master/src/vc.mak) mantém alvo Win32, e o [OpenSSL documenta `VC-WIN32` e `VC-WIN64A`](https://github.com/openssl/openssl/blob/openssl-3.5/NOTES-WINDOWS.md). Isso permite preparar uma build x86 atual, com assinatura, bibliotecas mantidas, toolchain/CRT compatíveis e revisão das DLLs/imports. Não fornece um executável pronto ou uma garantia de execução no Windows 7.

Uma opção para essa build é a linha [OpenSSL 3.5 LTS, com manutenção prevista até abril de 2030](https://openssl-library.org/post/2025-02-20-openssl-3.5-lts/), usando atualização de segurança vigente no momento do preparo. **Não retornar ao antigo stunnel de 32 bits nem a bibliotecas fora de manutenção para contornar a falta do bundle.** No perfil x64, o instalador atual também precisa passar pelo ensaio do Windows 7; o nome `win64` isoladamente não comprova compatibilidade.

## Assinaturas, certificados e TLS

Windows 7 SP1 precisa conseguir validar assinaturas SHA-2 e cadeias de confiança atuais. A Microsoft descreve [KB4474419, KB4490628 e reinício](https://support.microsoft.com/en-gb/servicing/os/windows/2020/09/2019-sha-2-code-signing-support-requirement-for-windows-and-wsus) como preparação. Atualizações cumulativas podem substituir esses componentes: a ausência de um número em uma listagem de hotfixes não prova, sozinha, falta do recurso. A verificação efetiva de Authenticode, o hash e o editor aprovados continuam decisivos; não liberar executável sem assinatura válida porque um KB consta da máquina.

O canal HTTPS do monitor depende do Schannel/.NET; o túnel stunnel usa sua biblioteca TLS. Ambos precisam negociar TLS 1.2 ou superior e validar cadeia e nome normalmente. O [Schannel do Windows 7 tem um conjunto próprio de algoritmos](https://learn.microsoft.com/en-us/windows/win32/secauthn/tls-cipher-suites-in-windows-7), portanto a conexão real à API e ao gateway precisa ser testada com as políticas efetivas do servidor. Não ignorar erro de certificado, desativar revogação, habilitar protocolo antigo nem reduzir políticas globais do sistema para obter conexão. Erro de TLS deve produzir diagnóstico e recusa.

Neste candidato, os caminhos utilizados pelo transporte e sua pasta de dados precisam ser ASCII. Nome de perfil Windows com acento pode bloquear a preparação remota; a correção desse caso exige preparar e validar um caminho de estado adequado, sem afrouxar a validação ou improvisar a codificação do stunnel. Essa limitação não impede o inventário local.

## Supervisão no Windows 7

O Windows 7 [não suporta Jobs aninhados](https://learn.microsoft.com/en-us/windows/win32/procthread/job-objects). O adaptador verifica se o Host já está associado a um Job herdado e, nesse caso, bloqueia a tentativa antes de executar filhos. Não usa breakaway, não altera o Job de outro programa e não inicia UltraVNC/stunnel sem supervisão.

Quando o contexto permite, cada processo próprio continua sendo criado suspenso, associado ao Job privado e liberado somente após as verificações. Morte do Host, expiração, perda de confirmação central, saída de um filho, pausa, bloqueio ou troca de console encerram o conjunto próprio. O monitor não encerra processos antigos por nome ou por PIDs de journal e não retoma consentimento após crash. Se a atribuição de um filho ao Job falhar, o supervisor mantém o handle próprio até comprovar sua saída. Uma limpeza de resultado incerto impede confirmar `ProcessesStopped` e o encerramento central; não descarta o handle nem anuncia uma parada que não foi comprovada.

## Ensaio pendente antes de qualquer disponibilização

1. Confirmar o UUID, a versão/SP1, a arquitetura nativa, o processo e o CLR/.NET do computador escolhido na loja 49. O hostname do Windows não define o código do caixa.
2. Selecionar e revisar o bundle correspondente ao perfil. Para x86, construir e assinar o stunnel atual antes de habilitar o perfil. Conferir dependências, origem, licenças, hashes, assinaturas, INI e permissões sem misturar DLLs de outra instalação.
3. Preparar configuração schema `2` e certificados individuais em diretório administrativo protegido. Preparar servidor e autorizações mínimos somente no ambiente e momento expressamente autorizados. O pacote local 0.7.0 inclui os 22 arquivos do núcleo e o preparo administrativo inativo; gerar esse pacote não aplica migração, publica ambiente, instala binários de terceiros ou habilita o acesso.
4. Fora do atendimento, comprovar HTTPS/mTLS, tela e entrada, consentimento/recusa/timeout, bloqueio/UAC/troca de console, perda de rede, revogação, pausa, crash, prazo e ausência de listeners/processos ao terminar. No Windows 7, testar também o bloqueio por Job herdado e a arquitetura divergente. Cada perfil exige registro próprio do resultado.
5. Conferir impressão Bematech e TEF sem venda ou pagamento em andamento. Manter Defender e eventual Panda ativos; investigar detecções por hash/classificação sem desativar proteção ou criar exclusões amplas. Assinatura válida não garante ausência de alerta.
6. A geração do candidato 0.7.0 já está autorizada. A instalação/teste na loja e a publicação de servidor, Conecta/API e feed correspondem à implantação posterior; a homologação real de cada perfil continua obrigatória antes de habilitar o remoto. Não enviar o novo conjunto de 22 arquivos ao atualizador 0.6. Atualizações da extensão administrativa exigem revisão separada.

Compilação do C# e testes de lógica com mocks em macOS/PowerShell 7 não executam Win32, WinForms, DPAPI, Schannel ou os programas reais. Esses resultados demonstram verificações locais do código, **não constituem homologação do Windows 7, dos binários, do antivírus ou da impressão/TEF**.
