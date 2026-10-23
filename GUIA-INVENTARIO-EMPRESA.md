# Inventário da empresa e histórico de componentes — 0.6.0

Esta entrega prepara o monitor, a API e a tela do Conecta para substituir o inventário do Techwatch. A API, as tabelas e o painel precisam ser integrados e publicados pelo responsável pelas versões do Conecta. Nenhum deploy ou importação real do Techwatch foi executado nesta entrega.

## Identificação do computador

O cadastro central tem um identificador próprio do ativo. A placa-mãe é sua referência física principal, usando fabricante, produto e número de série junto do UUID SMBIOS do equipamento. CPU, módulos de RAM, discos e adaptadores são componentes observados desse cadastro.

Essas evidências não são uma autenticação do equipamento: números de série podem faltar, ser genéricos ou repetir, e o firmware pode informar UUID vazio. O sistema preserva os dados conhecidos e sinaliza identificação insuficiente. Não reúne computadores automaticamente por nome do Windows, loja, MAC, modelo ou CPU.

`ProcessorId` descreve características do processador; não é usado como número de série universal. O UUID SMBIOS também é diferente do UUID de ativação do Nerus Service. A instalação do monitor permanece vinculada ao ativo por seu cadastro central: reinstalar usando outra instalação exige revisão para conciliar os cadastros, sem fusão automática.

Quando uma evidência conhecida da placa-mãe ou o UUID muda, a continuidade do ativo fica pendente de revisão. Não se deve concluir automaticamente que é outro computador ou que houve troca física sem examinar os dados. A primeira leitura de um campo novo amplia a referência inicial e não comprova uma troca.

Referências: [placa-mãe no Windows](https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-baseboard), [UUID SMBIOS](https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-computersystemproduct) e [ProcessorId](https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-processor).

## Histórico de alterações

A primeira coleta é a referência inicial. Coletas posteriores completas por componente permitem comparar a memória total, os módulos e seus slots, a CPU, os discos, os adaptadores, a placa-mãe e a versão do Windows. O histórico mostra os valores anteriores e os observados e a qualidade da identificação disponível.

Uma substituição de RAM com a mesma capacidade pode ser reconhecida quando o número de série ou outros dados suficientes do módulo/slot mudarem. Sem esses dados, o sistema informa somente a alteração observável; dois módulos idênticos sem série não permitem comprovar a troca.

O horário é **mudança detectada em**, acompanhado da observação anterior quando disponível. É um intervalo de descoberta, não o horário exato da intervenção. Horários de captura, boot, espaço livre e ordenação incidental não geram troca de hardware. Uma observação atrasada não desfaz uma mais recente.

A consulta informa a cobertura separada da placa-mãe, CPU, RAM, discos e adaptadores. Uma falha de consulta ou limite de itens não significa remoção: preserva-se a parte anteriormente conhecida e comparam-se apenas as partes que puderam ser observadas. O documento parcial fica separado da última coleta completa no monitor.

## Aplicativos e avisos de proteção

O monitor lê somente os metadados dos aplicativos registrados nas visões de 32/64 bits de HKLM e do usuário atual. Não usa `Win32_Product`, que pode disparar reparos MSI. Não cobre automaticamente aplicativos portáteis, Microsoft Store ou perfis de outros usuários. A data informada pelo instalador pode ser de atualização, e aparece como data declarada, não como instalação comprovada.

Quando disponível, consulta as detecções do Microsoft Defender por campos permitidos: identificação, nome, gravidade, estado ativo e resultado informado da ação. Não lê arquivos detectados nem seus caminhos, teclas digitadas ou conteúdo pessoal. Proteção indisponível, especialmente no Windows 7 ou com outro antivírus, não significa máquina sem ameaças.

O Conecta recebe uma lista administrável de softwares para revisão: nome exato e fabricante opcional, categoria, gravidade, motivo e referência. O catálogo inicial inclui OpenVPN Connect, WireGuard, Proton VPN/ProtonVPN, Tailscale e REFOG Personal Monitor, com fontes oficiais. A inclusão começa desativada para a manutenção revisar a política da empresa. VPN é uma categoria de uso, não prova de malware. Um nome no Registro também não comprova que um keylogger esteja ativo. Ameaças confirmadas pelo antivírus aparecem separadas desses avisos.

Não há remoção, bloqueio ou execução automática de aplicativos. O objetivo é informar a manutenção e preservar evidências suficientes para análise.

## Integração e piloto

1. Integrar os arquivos preparados da API e do painel à branch apropriada do Conecta.
2. Revisar e aplicar as tabelas do monitor, patrimônio, automação e inventário empresarial no ambiente pretendido. O piloto informado usa `conecta_feirao_hm`; não extrapolar para outra base.
3. Publicar primeiro a API e o painel. Conferir acesso dos usuários da manutenção e permissões administrativas para regras e vínculos.
4. Atualizar um monitor de teste para 0.6.0 e verificar patrimônio, softwares, cobertura e registros de dispositivos. A atualização do programa continua validando assinatura e preservando configurações e filas.
5. Simular em equipamento de laboratório uma alteração conhecida, conferir os valores anteriores/atuais e a data detectada. Os testes automatizados desta entrega usam mocks, sem tocar equipamentos reais.
6. Revisar a importação do Techwatch em modo de simulação antes de executá-la. O legado deve manter sua origem e seus valores originais, sem assumir unidade de RAM ou correspondência automática entre nome do Windows e caixa.

O inventário de hardware é consultado no início e a cada seis horas; consultas parciais tentam novamente após quinze minutos. Aplicativos e proteção são consultados a cada quinze minutos. Somente mudança, início ou renovação de 24 horas produzem remessa estruturada. Softwares possuem limite de 128 KiB, até 500 aplicativos e 64 detecções, com cobertura explícita. O hardware permanece limitado a 32 KiB e 16 itens por lista.

As filas de eventos e softwares são independentes. A API só confirma software com HTTP 204 após persistência; tentativas repetidas conservam o identificador do documento pendente. Com API anterior, o monitor preserva a pendência e aguarda para tentar novamente. Não modifica tabelas nem recebe credenciais do banco no Windows.

O comportamento de COM/Nerus continua documentado em [GUIA-NERUS-SERVICE.md](GUIA-NERUS-SERVICE.md): a versão não comprova falha interna de impressão, não altera COM por conta própria e não reinicia componentes durante uma venda sem a confirmação local exigida pelo fluxo assistido.
