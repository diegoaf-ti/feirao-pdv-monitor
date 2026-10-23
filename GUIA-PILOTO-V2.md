# Piloto v2 — hardware e ocorrências do PDV

Esta versão está preparada para teste acompanhado. O código publicado em branch não atualiza sozinho o servidor `nxstore.shop` nem o programa instalado no caixa.

## Publicar sob coordenação de Jeremias

1. API: revisar [PR #6](https://github.com/jeremiascb/conecta-feirao-api/pull/6). Confirmar que `DB_NAME_CONECTA` e `SELECT DATABASE()` indicam **`conecta_feirao_hm`**. Aplicar manualmente `database/ddl/create_pdv_monitor_hardware.sql` antes de publicar a API. O arquivo requer as duas tabelas originais e acrescenta a tabela de hardware e um índice. Não executar em outra base por dedução do nome do domínio.
2. Publicar a API v2. Os monitores antigos continuam aceitos. O [PR #4 da API](https://github.com/jeremiascb/conecta-feirao-api/pull/4), sobre erro de migração ausente, permanece separado; preservar os ajustes dos dois PRs ao integrar o controller.
3. Publicar o painel do [PR #4 do Conecta](https://github.com/jeremiascb/conecta-feirao/pull/4). Conferir as seções **Ocorrências importantes**, **Inventário das máquinas** e **Instalações**.
4. Só então atualizar o programa Windows do caixa piloto. Encerrar a instância anterior pelo ícone da bandeja e substituir a pasta completa do programa, preservando os arquivos de dados do usuário. Se houver instalação automática, seguir o procedimento de reinstalação do README. Não apagar `%LOCALAPPDATA%\Feirao\PdvMonitor`.

Não é necessário revogar a instalação nem gerar outra chave para esta atualização. A chave protegida pelo Windows continua vinculada ao mesmo usuário.

## Preparar a referência do caixa

Selecionar a impressora e o pinpad corretos no monitor e salvar um vínculo para cada função. Confirmar a COM esperada de cada equipamento com a configuração efetivamente utilizada naquele caixa. Os alertas dependem desses vínculos; o monitor não lê `fiscalDevice` diretamente do Nerus. O cadastro da instalação na central identifica loja e caixa, mas não substitui o vínculo local do periférico.

O exemplo informado pelo suporte foi `fiscalDevice=3` selecionando COM4 no CX4901. Esse caso não valida a fórmula COM menos um para outras portas. Não usar uma instalação identificada como teste para alterar parâmetros de um caixa real.

## Conferir fora de uma venda

- Manter a recuperação desarmada. Comparar a presença e a COM do monitor com o Gerenciador de Dispositivos e registrar o horário do teste.
- Conferir fabricante, modelo, série, Windows, CPU, memória e discos na central. Campos desconhecidos devem continuar desconhecidos. Estado `OK` do disco é apenas o informado pelo Windows, sem teste SMART completo.
- Simular uma divergência alterando apenas a COM esperada no perfil do monitor. Após três leituras completas, conferir o alerta com porta esperada e atual; restaurar o perfil e conferir a resolução. Não renumerar a porta do Windows para realizar esse teste.
- Fora de uso, desconectar e reconectar um periférico de cada vez. A ausência confirmada deve produzir um incidente, sem repetição a cada consulta. Uma consulta parcial ou presença desconhecida não deve afirmar desconexão.
- Interromper a rede, verificar a fila local e restabelecer a conexão. Eventos só são retirados após HTTP 204. Conferir ausência de duplicação e chegada do inventário.
- Conferir que os inventários normais de drivers, filas e reservas deixaram de gerar novas linhas periódicas. O histórico antigo continua disponível em **Ver registros técnicos**.

Um equipamento reaparecer no Windows não confirma impressão ou comunicação com o TEF. Confirmar a operação no próprio PDV ao terminar o teste.

## Recuperação e limites desta entrega

O diagnóstico de COM funciona com a recuperação desarmada. O reinício de uma instância elegível continua restrito à janela manual de manutenção e às verificações do README; não equivale a trocar a COM nem recarregar a DLL do Nerus.

O plano de correção da configuração Nerus está em `PLANO-CORRECAO-NERUS.md`. A escrita autônoma depende de um mapeamento homologado, de um sinal confiável de caixa sem venda/TEF em andamento e de uma forma suportada de recarregar e validar a comunicação. Esta versão não executa esse SQL, não encerra processos do caixa e não abre a porta para teste.

## Evidências e acompanhamento

Os testes automatizados usam banco e dispositivos simulados. Incluem o caminho real de serialização do coletor ao validador da API, Unicode, números grandes, falhas de rede, confirmação e preservação do último inventário válido. A integração com equipamentos e coleta nativa ainda precisa deste piloto Windows.

Para cada ocorrência real, guardar horário, loja/caixa, equipamento, porta esperada/atual, mensagem do PDV e resultado da intervenção. Esses dados permitem distinguir mudança de porta, falha de driver, ausência física e comunicação retida pela aplicação.
