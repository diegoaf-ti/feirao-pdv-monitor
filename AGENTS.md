# Regras do monitor de PDV

- Responder em Português Brasil.
- Monitor e iniciadores devem preservar sintaxe compatível com Windows PowerShell 2.0. A interface moderna de diagnóstico pode exigir 5.1; os testes podem exigir 5.1/7.
- Salvar scripts PowerShell em UTF-8 com BOM. Os iniciadores CMD/VBS usam ASCII.
- Separar host de bandeja, coleta, política pura, runtime e transporte. Não abrir portas COM para testar presença nem carregar a DLL do TEF no monitor.
- Não ler arquivos de pagamentos, dados de cartão, mensagens completas de impressão ou segredos do Nerus/SiTef.
- As escritas locais são configuração/logs próprios e a atualização assinada do próprio programa. Não alterar COM, Registro, drivers ou serviços automaticamente. O ajuste autorizado de fiscalDevice ocorre exclusivamente pela API, com política por instalação, evidências recentes, ticket, CAS e auditoria transacional; sem SQL livre ou credencial de banco no caixa.
- Recuperação local de dispositivo exige identidade exata, janela de manutenção explícita, verificações recentes e limites persistidos. A correção Nerus usa a janela cadastrada pelo administrador, com PDV/TEF fechados e fila de impressão vazia. O usuário autorizou uma tentativa assistida de fechar e reabrir somente o Nerus pelo atalho local identificado: exigir confirmação do operador por operação, fechamento normal sem forçar, identidade exata do processo, consulta prévia da divergência e estado persistido antes de cada ação. Não encerrar CliSiTef, não aceitar diálogos do ERP automaticamente e não reabrir com escrita de resultado incerto. Não reativar dispositivo desabilitado nem tentar reiniciar dispositivo ausente, hub ou controlador.
- Nunca colocar credenciais no repositório. A chave de telemetria deve usar DPAPI CurrentUser e ficar fora da exportação.
- Usar somente HTTPS com validação padrão de certificado. Manter fila durável e identificador de evento em reenvios. Somente confirmação integral do servidor permite retirar registros da fila.
- Testes devem usar mocks e diretórios temporários. Não executar os scripts de instalação, recuperação ou coleta real no ambiente de desenvolvimento sem autorização para a máquina alvo.
- Validar mudanças de protocolo contra o backend do Conecta, principalmente limites, tipos, códigos de problema desconhecidos e reenvio idempotente.
- O teste em macOS não comprova funcionamento do Windows PowerShell 2.0/5.1, WMI, Event Log, WinForms, DPAPI, TLS ou equipamentos. Registrar essas limitações com clareza.
