# Nerus Service: diagnóstico e recuperação assistida

Entrega para piloto acompanhado. Esta função precisa ser instalada e validada no caixa; não significa que esteja ativa nas lojas. A entrega não publica o Conecta ou a API nem altera o banco de dados.

## O que o documento do fornecedor confirma

O PDF **Instruções para Implantação — Caixa Web — PONTO DE VENDA**, enviado em 21/10/2026, descreve o Caixa Web no navegador e um componente local do Nerus com DLLs, ícone na bandeja, estado de conexão e identificação de ativação. Orienta Windows 10 de 64 bits e Google Chrome.

O documento não fornece nome de serviço Windows, caminho exato do executável, comando de reinicialização ou uma API para recarregar DLLs. Ter um ícone na bandeja não comprova registro no gerenciador de serviços. O monitor apresenta candidatos para o suporte conferir; não escolhe ou autoriza um processo apenas porque seu nome contém Nerus.

## Preparar o vínculo no caixa

1. Instalar a nova versão completa e abrir o monitor com o usuário habitual. Preservar os vínculos da impressora/pinpad e os dados de envio central.
2. Abrir **Nerus Service (Caixa Web)...** para consultar os candidatos. Conferir com o suporte a instalação local e o serviço que realmente atende ao Caixa Web.
3. Salvar o vínculo exato do serviço e do executável. Reinstalação, alteração da identidade ou do executável exige nova conferência; um candidato parecido não substitui o vínculo automaticamente.
4. Conferir o vínculo local da impressora e sua COM esperada. A tentativa requer uma única impressora vinculada, presente e saudável em três leituras completas, com COM igual à referência, sem conflito e sem impressão pendente. Se a porta mudou, esta função bloqueia a tentativa e informa a divergência; ela não renumera a COM do Windows.
5. Conferir os nomes reais dos processos bloqueadores configurados e confirmar com o fornecedor se o mesmo componente controla impressão e TEF. O monitor não identifica tecnicamente uma venda ativa: não reiniciar enquanto houver venda, pagamento, cancelamento ou impressão em andamento.

A descoberta e os registros podem funcionar sem privilégio de administrador. A recuperação depende de acesso administrativo ao serviço e ao processo. O monitor não pede elevação sozinho; quando não puder comprovar as condições, informa o bloqueio.

## Executar uma tentativa assistida

1. Finalizar ou cancelar venda e pagamento, aguardar as impressões e deixar o caixa sem nova operação durante a sequência.
2. Usar a opção de recuperação do Nerus Service. O monitor refaz a leitura do serviço vinculado e apresenta a confirmação ao operador. **Não** é a resposta padrão; **Sim** autoriza somente aquela operação.
3. A tentativa aceita somente um serviço Windows em processo próprio, com identidade e executável conferidos, sem serviços dependentes ativos, outros serviços compartilhando o processo ou processos filhos. Um componente que seja apenas aplicativo de bandeja fica disponível para diagnóstico, sem encerramento pelo monitor.
4. O monitor salva o estado da tentativa antes da ação, solicita a parada normal e aguarda sua confirmação e a saída do processo responsável. Se o serviço recusar, demorar ou mudar de identidade, interrompe a sequência; não força encerramento.
5. Com a parada comprovada e as condições ainda válidas, inicia o mesmo serviço uma vez. Se houver falha ou resultado incerto, informa a situação para análise. Reiniciar o monitor não repete automaticamente a tentativa pendente.
6. Reabrir ou atualizar o Caixa Web quando necessário e validar a impressão antes de retomar o atendimento. O monitor não aceita diálogos do ERP, não efetua pagamentos e não imprime testes.

Há intervalo mínimo de **15 minutos** e limite de **duas tentativas por hora**, mantidos em disco. Falha no estado persistido bloqueia novas ações. Enquanto houver recuperação em andamento, não iniciar outra manutenção ou atualização do monitor.

Essa recuperação **não altera a COM do Windows nem fiscalDevice**, não alterna para uma porta errada, não reinicia CliSiTef separadamente e não reinicia o computador. Ela pode ser usada quando a porta já estiver correta. Encerrar e iniciar o processo responsável permite uma nova inicialização das bibliotecas utilizadas por ele, mas o resultado do serviço não comprova a impressão.

## O que fica registrado

A descoberta consulta o Windows a cada 60 segundos e publica somente uma referência inicial e mudanças relevantes. Não gera um inventário completo a cada rodada.

O monitor contínuo não consulta o Event Log nesta versão. O acompanhamento fica concentrado nos dispositivos/COM vinculados, componente Nerus, patrimônio e registros operacionais do próprio monitor.

Os registros usam uma lista limitada de metadados: nome e estado do serviço, tipo, PID, informações de identidade e versão do executável e condições que impediram a tentativa. O caminho técnico do executável pode conter pasta de usuário. Não são gravados argumentos, linha de comando, credenciais, identificação de ativação do Nerus, arquivos de pagamento ou conteúdo de DLLs/configurações do fornecedor.

`ServiceDiagnostic` utiliza o contrato existente de eventos: o JSON compacto fica em `Detail`, com no máximo 2.000 caracteres, sem acrescentar campos ao envelope. A central pode receber e armazenar esses eventos sem nova tabela. Na versão atual do painel, eles aparecem na visualização completa como registros de rotina; a apresentação específica de serviço ainda depende de integração e publicação do Conecta. Falhas de recuperação também ficam registradas com o motivo.

Os eventos descrevem o que o Windows confirmou. Serviço em execução, PID novo, COM presente ou DLL carregada não comprovam comunicação com a Bematech. Anotar o horário e a mensagem do Caixa Web e fazer a conferência de impressão para correlacionar o resultado.

O vínculo fica em `nerus-servico.xml`, as etapas/limites em `nerus-servico-tentativas.xml` e a última coleta em `nerus-servico-diagnostico.json`, na pasta de dados do monitor. Esses arquivos técnicos entram em **Exportar diagnóstico...**; a credencial de envio permanece excluída. Não apagar o histórico para contornar um bloqueio ou um resultado incerto.

## Validar o primeiro piloto

Fazer o teste acompanhado, fora de atendimento. Confirmar o serviço com o fornecedor, verificar vínculo e privilégios e testar primeiro a recusa na confirmação: nenhuma ação deve ocorrer. Depois autorizar uma tentativa e conferir parada, saída do processo, nova execução, acesso do Caixa Web e impressão. Validar também o bloqueio quando o serviço não puder ser identificado com segurança.

Os testes automatizados usam simulações. Eles não comprovam o funcionamento do serviço real, do driver, das DLLs, do Windows 7 ou dos equipamentos. Se o componente instalado não for um serviço Windows elegível, a entrega registra o diagnóstico e não tenta encerrá-lo; será necessária uma integração específica validada com o fornecedor.
