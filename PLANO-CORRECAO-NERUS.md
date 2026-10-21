> Este documento registra o desenho anterior. Consulte a implementação e os procedimentos atuais em [GUIA-PILOTO-V3.md](GUIA-PILOTO-V3.md). As frases abaixo sobre integração ainda não implementada pertencem à proposta histórica.

# Histórico da proposta de correção Nerus (evoluído na versão 0.3.0)

Esta proposta descreve a próxima integração. O monitor atual identifica alterações
de COM, falhas e desconexões e as apresenta ao suporte; ele ainda não escreve a
configuração do Nerus nem oferece comando remoto para alterá-la.

O objetivo é dispensar o acesso remoto ao caixa quando o Windows reconhece a
impressora em uma porta diferente daquela usada pelo Nerus. A solução proposta é
ajustar a referência do Nerus à impressora identificada, depois de confirmar que o
caixa está fora de operação. Fixar números COM pelo registro do Windows não resolve
a recarga da configuração do Nerus e pode criar conflitos.

## O que foi confirmado

No atendimento relatado, a impressora do terminal `CX4901` passou a usar COM4 com:

```sql
update sqlparam.param
set conteudo__480 = 3
where terminal = 'CX4901' and varname = 'fiscalDevice';
```

Essa observação vale para esse terminal e essa configuração. Não foi validada uma
fórmula `valor = número da COM − 1` para outras portas, modelos ou versões. Também
não foi confirmado que o pinpad use `fiscalDevice`; a impressora e o TEF precisam de
integrações distintas.

O funcionamento após alternar a configuração e reabrir o sistema sugere retenção
de estado ou recarga tardia, mas não comprova a causa nem um procedimento suportado
de recarga. Não vamos transformar a alternância de portas em uma rotina automática.

## Diagnóstico já implementado

- Inventário consolidado da máquina separado dos incidentes de suporte.
- Referência de equipamento por identidade exata e porta esperada, quando cadastrada.
- Incidentes de mudança/conflito de COM, desconexão, retorno e falha concreta.
- Confirmação por três leituras completas antes de consolidar uma mudança; presença
  desconhecida não equivale a desconexão.
- Histórico com porta esperada/atual e motivos que impedem recuperação.

O reinício de dispositivo já existente é uma ação diferente: permanece sujeito às
proteções de manutenção, identidade, estado e limites. O comando de reinício de uma
instância existe a partir do Windows 10 versão 2004, conforme a documentação do
[PnPUtil](https://learn.microsoft.com/en-us/windows-hardware/drivers/devtest/pnputil-command-syntax).
Ele não reconfigura a porta do Nerus nem garante que a impressão voltou.

## Integração proposta

Criar um adaptador específico do Nerus, separado da credencial atual de telemetria.
O backend prepararia uma operação estruturada para um terminal e um perfil de
impressora, com validade curta e identificador único. O agente local verificaria o
estado atual antes de executar qualquer etapa suportada pelo Nerus. Não haveria
SQL livre, script remoto nem credencial de banco distribuída aos caixas.

O primeiro piloto ficaria limitado ao `CX4901`, à impressora previamente pareada e
ao mapeamento homologado para a sua versão. Outros caixas só seriam habilitados
depois de registrar seus próprios vínculos e confirmar o comportamento.

### Condições para habilitar

| Condição | Evidência necessária |
| --- | --- |
| Impressora correta | Identidade exata cadastrada, modelo e número de série quando disponíveis; fabricante ou nome amigável sozinho não basta. |
| Mudança estável | Três leituras completas e concordantes, seguidas de nova coleta imediatamente antes da alteração. |
| Porta sem ambiguidade | Uma única instância presente associada à porta; ausência de conflito entre perfis e equipamentos. Reserva COM isolada não prova quem utiliza a porta. |
| Terminal real | Vínculo validado entre instalação do monitor, máquina e terminal efetivamente carregado pelo Nerus; não deduzir apenas pelo hostname. |
| Mapa de parâmetros | Tabela de valores homologada com Nerus para essa versão, driver e modelo. `3 → COM4` é a única associação já observada. |
| Caixa ocioso | Sinal confiável do Nerus de ausência de venda e de operação TEF, inclusive inicialização/finalização; nenhuma impressão pendente ou uso direto da impressora. |
| Autorização | Adesão explícita do administrador por terminal/perfil e janela de manutenção definida. Falha na consulta de estado bloqueia a escrita. |
| Recarga | Forma documentada de aplicar a configuração no Nerus, com resposta verificável e sem interromper venda ou TEF. |

Ausência de processos ou fila de impressão vazia, isoladamente, não prova que o
PDV está ocioso. É necessário um contrato de estado com o Nerus ou um bloqueio de
manutenção reconhecido pelo próprio PDV. Enquanto isso não existir, a integração
pode preparar a correção e mostrar o motivo, mas não executá-la automaticamente.

### Escrita controlada

Antes de qualquer piloto de escrita, verificar a chave primária e a unicidade da
configuração do terminal, as permissões e o mecanismo de armazenamento de
`sqlparam.param`. Se houver mais de uma linha correspondente, a operação deve parar.
Não selecionar uma linha arbitrária nem usar `LIMIT 1` para esconder duplicidade.

O fluxo proposto é:

1. Ler a configuração e sua revisão sob exclusão reconhecida pelo Nerus; conferir
   novamente identidade, porta, vínculo, autorização e ociosidade.
2. Preservar uma cópia do valor anterior e registrar a operação, o diagnóstico,
   quem autorizou, o alvo e o valor pretendido. A operação tem chave de idempotência.
3. Atualizar somente a linha identificada, comparando o valor/revisão lidos com os
   atuais — uma troca condicional, ou CAS. Exigir exatamente uma alteração.
4. Gravar alteração e auditoria na mesma transação, com todos os mecanismos
   envolvidos efetivamente transacionais. Se a tabela for MyISAM, não prometer
   rollback; a escrita permanece bloqueada até definir uma integração suportada.
5. Solicitar a recarga pelo mecanismo homologado e verificar a configuração que o
   Nerus efetivamente carregou.
6. Confirmar uma impressão de teste não fiscal, previamente autorizada para o
   piloto, ou uma confirmação equivalente suportada pelo Nerus. Porta presente e
   retorno de comando do Windows não bastam para marcar o incidente como corrigido.

A comparação apenas do valor pode não detectar uma alteração concorrente que
mudou e voltou ao valor anterior. A versão da linha ou a exclusão fornecida pelo
Nerus precisa fazer parte do contrato. Não acrescentar colunas ou mudar o mecanismo
de tabelas do ERP por conta do monitor.

Banco confirmado e recarga de aplicativo não formam uma única transação. Se a
recarga ou o teste falhar, registrar “configuração alterada, comunicação ainda não
confirmada” e bloquear novas tentativas. Uma reversão só pode usar o backup quando
a revisão/exclusão demonstrar que ninguém alterou a configuração desde então;
caso contrário, preservar o estado e encaminhar a divergência ao suporte.

Os estados visíveis seriam: **detectado → aguardando caixa ocioso → configuração
aplicada → aguardando confirmação → corrigido**. Qualquer ambiguidade vira
**precisa de suporte**, com o motivo. A simples solicitação de reinício nunca vira
“corrigido”. Repetir a mesma operação não pode executar uma segunda alteração.

## TEF: alternativa a homologar com CliSiTef

Para Gertec PPC920/PPC930, a documentação informa identificação automática da
porta USB com `Porta=AUTO_USB`, na seção `PinPadCompartilhado`, a partir de CliSiTef
4.0.111.3, restrita na página à plataforma Windows 32. Precisamos confirmar o
modelo real, a versão e arquitetura da biblioteca carregada pelo Nerus antes de
testar. A existência do recurso não comprova recuperação após desconexão nem
dispensa homologação da aplicação. [Configuração da porta — Software Express](https://dev.softwareexpress.com.br/docs/clisitef/configuracao_da_porta/).

Também existe `PortaPinPad` nos parâmetros especiais de inicialização. É necessário
verificar se o Nerus o fornece e confirmar com o fornecedor a precedência em relação
ao INI; não assumir que mudar o arquivo será suficiente. [Configurações especiais
gerais — Software Express](https://dev.softwareexpress.com.br/docs/clisitef/configuracoes_especiais_gerais/).
O contexto completo fica na [especificação principal CliSiTef](https://dev.softwareexpress.com.br/es/docs/clisitef/clisitef_documento_principal/).

## O que não faz parte da proposta

Não alternar artificialmente COM1/COM2/COM4 para provocar recarga, encerrar processos,
injetar ou descarregar DLL, renumerar portas no registro, liberar reservas à força,
reiniciar o computador ou executar transações TEF como teste. A Microsoft descreve
`ComDBClaimPort` como registro de um número reservado; essa base não identifica o
equipamento que o reservou. Portanto, reservar COM4 não vincula a impressora à COM4.
[ComDBClaimPort — Microsoft](https://learn.microsoft.com/en-us/windows/win32/api/msports/nf-msports-comdbclaimport).

## Critério para aprovar o piloto automático

Primeiro observar o adaptador sem escrita: ele deve produzir o plano correto para
as falhas reais e recusar dispositivo parecido, presença desconhecida, leitura
incompleta, conflito, terminal incorreto e caixa ocupado. Depois homologar uma
única correção fora de operação e provar recarga e impressão, concorrência,
retransmissão, falha de banco e falha de recarga. Somente então habilitar a ação
automática nesse perfil, com limites de tentativa, auditoria e possibilidade de
desativação central.

Para avançar, precisamos obter com Nerus o mapa de `fiscalDevice`, a identificação
do terminal em execução, o sinal confiável de ociosidade e a forma suportada de
recarregar a impressora. Sem esses quatro contratos, a detecção já reduz o trabalho
do suporte, mas a correção automática de configuração ainda não está implementada.
