# Monitor do PDV 0.7.1 — piloto para teste acompanhado

O pacote contém o aplicativo Windows com interface e ícone na bandeja. Ele reúne inventário de hardware e programas, histórico de dispositivos/portas COM, envio central e as rotinas de recuperação já preparadas. O suporte remoto está integrado, mas fica **aguardando preparação** até receber o componente administrativo, as dependências aprovadas, os certificados e o servidor central.

Este pacote não atualiza o Conecta ou a API, não aplica SQL e não instala nada nas lojas por conta própria. A instalação e os testes Windows ainda precisam ser executados no computador escolhido. O ensaio local em macOS não comprova impressão, TEF, Windows, antivírus ou uma sessão remota real.

## Instalação no computador de teste

1. Encerre o monitor anterior pelo ícone da bandeja. Não é necessário encerrar o Nerus ou o TEF para instalar o monitor; uma tentativa de recuperação tem verificações próprias e não deve ocorrer durante venda/pagamento.
2. Extraia **todo o ZIP** para uma pasta. Não execute diretamente de dentro do arquivo compactado.
3. Entre com o mesmo usuário Windows que usa o monitor anterior e abra **Instalar.cmd**. A instalação comum é por usuário; não a execute com outra conta administrativa, pois as credenciais locais são protegidas para o usuário original.
4. A instalação preserva a pasta de dados e copia apenas os arquivos do aplicativo. O início automático usa a pasta de Inicializar do usuário. Depois, confira a abertura, a versão 0.7.1, os dispositivos e o estado do envio central.
5. Se for uma máquina nova, use **Configurar envio central** e os dados de instalação emitidos pelo Conecta. Não reutilize a chave de outro computador. O nome do Windows não determina o código do caixa.

O aplicativo fica em `%LOCALAPPDATA%\Feirao\PdvMonitor\programa`; configurações, logs e credencial permanecem na pasta de dados do mesmo usuário. **Não apague essa pasta para atualizar.** `Monitor.cmd` permite abrir a interface sem instalar o início automático.

## Atualização de versões anteriores

A primeira passagem de 0.6 ou anterior para 0.7 precisa dessa instalação manual. O atualizador antigo aceita um conjunto menor de arquivos e recusará o pacote ampliado; não enviar o novo pacote ao feed antigo. Depois de instalada a 0.7, as atualizações do núcleo usam assinatura e a lista fechada de 22 arquivos, com proteção de backup/restauração.

O arquivo `atualizacao/0.7.1.zip`, quando entregue separadamente, é um pacote técnico de atualização do núcleo. **Não é o instalador inicial** e não deve ser copiado para substituir arquivos enquanto o monitor estiver aberto. O manifesto assinado não foi publicado em servidor ou ativado nas lojas.

## Suporte remoto

O estado **aguardando preparação** é esperado numa instalação comum. Ele não impede o inventário e o monitoramento local. O aplicativo não baixa programas de acesso, abre portas públicas ou concede controle automaticamente.

O administrador pode preparar o componente local usando `piloto-remoto\windows\PrepararRemoto.cmd`, conforme as instruções técnicas. Essa preparação é separada da instalação comum: copia somente código protegido para `%PROGRAMDATA%\Feirao\PdvMonitorRemoto\app`. Não recebe credencial do operador, não cria certificados, não copia perfil ativo e não habilita o acesso. Instalação administrativa existente não é sobrescrita automaticamente.

Para ativar um piloto, ainda são necessários servidor/gateway, API e painel correspondentes, autorização por técnico/computador, certificados individuais, perfil administrativo aprovado e programas de acesso compatíveis e assinados. Cada atendimento exige confirmação visível do operador, prazo limitado e opção de encerramento. Recuperação do Nerus e aplicação de atualização ficam bloqueadas durante o apoio.

O código admite Windows 7 SP1 de 32/64 bits e Windows 10/11, com perfis separados. O suporte remoto exige CLR 4 e .NET Framework 4.6.2 ou posterior; recomenda-se Windows PowerShell 5.1 com .NET 4.8 no Windows 7 SP1. **O componente de criptografia de 32 bits ainda exige uma compilação atual assinada e homologada; ela não integra esta entrega.** O perfil de 64 bits também precisa de ensaio real antes de habilitação. Veja `piloto-remoto/windows/COMPATIBILIDADE-WINDOWS7.md`.

Mantenha Defender e eventual Panda ativos durante os testes. O pacote usa scripts Windows legíveis, sem empacotador ofuscado; isso não garante ausência de alerta. A assinatura de atualização verifica integridade/origem do pacote técnico e não é uma assinatura Authenticode de editor nem homologação do antivírus.

## Conferência do teste

Confirme que o inventário chega ao ambiente correto, que uma perda/mudança de COM gera registro útil e que nenhuma recuperação começa durante venda ou pagamento. Teste o início automático após reiniciar com o mesmo usuário. No primeiro ensaio remoto, use o computador da loja 49 já indicado e mantenha uma pessoa no caixa para consentimento e validação de impressão/TEF.

Se uma função central ainda não estiver publicada no ambiente, sua indisponibilidade não deve ser tratada como coleta confirmada nem apagar a fila. O acesso remoto só poderá ser validado depois da preparação do servidor e dos componentes locais correspondentes.

## Certificado integrado na versão 0.7.1

O mesmo pacote contém as autoridades públicas e permite ativar um certificado próprio por computador, sem importar arquivos manualmente no Windows. Após preparar o componente administrativo, execute `piloto-remoto/windows/AtivarCertificadoRemoto.cmd` como administrador e informe o código temporário emitido para aquela instalação no Conecta. A chave privada é criada no computador e fica fora do ZIP e da exportação do monitor. Consulte [CERTIFICADO-EMBUTIDO.md](CERTIFICADO-EMBUTIDO.md).

O certificado não aprova executáveis nem habilita uma sessão. UltraVNC/stunnel compatíveis e assinados, perfil administrativo, autorização central e consentimento local continuam necessários. Não distribuir este ZIP no feed de atualização das versões 0.6 ou anteriores.
