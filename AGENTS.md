# Regras do monitor de PDV

- Responder em Português Brasil.
- Monitor e iniciadores devem preservar sintaxe compatível com Windows PowerShell 2.0. A interface moderna de diagnóstico pode exigir 5.1; os testes podem exigir 5.1/7.
- Salvar scripts PowerShell em UTF-8 com BOM. Os iniciadores CMD/VBS usam ASCII.
- Separar host de bandeja, coleta, política pura, runtime e transporte. Não abrir portas COM para testar presença nem carregar a DLL do TEF no monitor.
- Não ler arquivos de pagamentos, dados de cartão, mensagens completas de impressão ou segredos do Nerus/SiTef.
- As escritas locais permitidas são configuração e logs próprios. O monitor não altera COM, Registro, parâmetros SQL, drivers ou serviços automaticamente.
- Recuperação exige identidade exata, janela de manutenção explícita, verificações recentes e limites persistidos. Não reativar dispositivo desabilitado nem tentar reiniciar dispositivo ausente, hub ou controlador.
- Nunca colocar credenciais no repositório. A chave de telemetria deve usar DPAPI CurrentUser e ficar fora da exportação.
- Usar somente HTTPS com validação padrão de certificado. Manter fila durável e identificador de evento em reenvios. Somente confirmação integral do servidor permite retirar registros da fila.
- Testes devem usar mocks e diretórios temporários. Não executar os scripts de instalação, recuperação ou coleta real no ambiente de desenvolvimento sem autorização para a máquina alvo.
- Validar mudanças de protocolo contra o backend do Conecta, principalmente limites, tipos, códigos de problema desconhecidos e reenvio idempotente.
- O teste em macOS não comprova funcionamento do Windows PowerShell 2.0/5.1, WMI, Event Log, WinForms, DPAPI, TLS ou equipamentos. Registrar essas limitações com clareza.
