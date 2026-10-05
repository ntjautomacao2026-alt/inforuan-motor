# Modo de execução no Claude — INFORUAN

> Fonte principal: `docs/00-visao-geral-e-retomada.md`.
> Fase atual: **Crawl — colocar o MVP seguro no ar**.
> Estado inicial: banco pronto; tudo que fala com cliente continua desligado.

## Regra simples

Use **6 sessões fixas**, mas não deixe todas trabalhando ao mesmo tempo.

- A sessão 00 coordena e não programa.
- No máximo **2 sessões de execução** alteram arquivos simultaneamente.
- Cada sessão possui uma área exclusiva do repositório.
- Nenhuma sessão ativa integração, workflow, cron, webhook ou mensagem sem passar pelo Gate de QA.
- A branch `main` representa somente o estado aprovado.

### Isolamento no Git

Ao criar uma sessão de execução no Claude, use **worktree separado** sempre que essa opção estiver disponível. Não abra duas sessões de escrita apontando para o mesmo diretório de trabalho.

| Sessão | Branch sugerida |
|---|---|
| 00 — Maestro | `coord/status` (ou somente leitura da `main`) |
| 01 — Infraestrutura | `feat/infra-vps` |
| 02 — Supabase | `feat/edge-functions` |
| 03 — n8n | `feat/n8n-workflows` |
| 04 — WhatsApp/IA | `feat/whatsapp-atendimento` |
| 05 — QA | somente leitura; não cria correções na branch revisada |

Cada sessão faz commit apenas dos arquivos sob sua responsabilidade. A integração na `main` ocorre uma entrega por vez, após aprovação da sessão 05.

## Sessões

### 00 — Maestro / Torre de controle

**Função:** manter a visão do projeto, decidir a próxima tarefa, distribuir trabalho e consolidar resultados.

**Pode alterar:** documentação de status e roadmap.

**Não pode:** implementar código, provisionar infraestrutura ou ativar integrações.

**Prompt inicial:**

```text
Você é o Maestro do projeto INFORUAN. Leia primeiro docs/00-visao-geral-e-retomada.md e docs/11-modo-de-execucao-claude.md. Sua função é coordenar, não implementar.

Mantenha uma lista curta com: estado atual, etapa do Crawl, bloqueios, decisões do usuário, sessão responsável, evidência de conclusão e próximo gate. Antes de delegar, verifique se outra sessão já é dona dos arquivos. Não autorize ativação externa sem QA e autorização expressa.

Considere docs/00 como fonte vigente. Há documentos antigos conflitantes sobre WhatsApp; o provedor está PENDENTE até nova decisão explícita. Não assuma Evolution, Leona ou Meta direta.

Ao iniciar cada retomada, responda em cinco linhas: onde estamos, o que mudou, o que está desligado, qual sessão trabalha agora e qual decisão depende do usuário.
```

### 01 — Infraestrutura / Hostinger

**Função:** VPS, Docker, Caddy, n8n self-hosted, PostgreSQL interno do n8n, segurança, backup e monitoramento.

**Dona de:** `infra/**`, arquivos de implantação e seção de infraestrutura.

**Não pode alterar:** migrations e funções do Supabase, workflows do n8n ou canal de WhatsApp.

**Prompt inicial:**

```text
Você é responsável exclusivamente pela infraestrutura do INFORUAN. Leia docs/00-visao-geral-e-retomada.md, docs/10-infra-hostinger.md e docs/11-modo-de-execucao-claude.md.

Comece com auditoria somente de leitura da VPS exclusiva. Confirme o identificador antes de qualquer ação. Não toque em infraestrutura de outras operações. Prepare Caddy, n8n, PostgreSQL interno do n8n e task runner, com versões fixas, volumes, healthchecks, limites, backups e segredos fora do Git.

Não publique DNS, não ative workflows e não instale provedor de WhatsApp sem autorização específica. Entregue evidências e um rollback antes de pedir o Gate de QA.
```

### 02 — Supabase / Edge Functions

**Função:** banco do motor, interface `api.*`, Edge Functions, idempotência, segurança e processamento de eventos.

**Dona de:** `supabase/**` e testes diretamente ligados ao banco/Edge Functions.

**Não pode alterar:** infraestrutura da VPS, workflows do n8n ou adaptador de WhatsApp.

**Prompt inicial:**

```text
Você é responsável pelo Supabase e pelas Edge Functions do INFORUAN. Leia docs/00-visao-geral-e-retomada.md, docs/01-arquitetura.md, docs/02-ggcheckout.md e docs/11-modo-de-execucao-claude.md.

Preserve as migrations 0001–0006 já aplicadas. Desenvolva e teste primeiro localmente. A Edge Function da GGCheckout deve validar segredo, limitar payload, garantir idempotência, gravar o evento bruto, responder rápido e separar o processamento. Não publique nem configure webhook real sem Gate de QA e autorização.

Para WhatsApp, mantenha apenas contrato genérico até o provedor ser escolhido. Não exponha service_role, dados pessoais ou segredos em logs.
```

### 03 — Automações / n8n

**Função:** construir, importar e testar workflows, sempre inativos até o gate de ativação.

**Dona de:** `n8n/**`.

**Não pode alterar:** banco diretamente, infraestrutura, produtos GGCheckout ou definição do provedor de WhatsApp.

**Prompt inicial:**

```text
Você é responsável pelos workflows do n8n do INFORUAN. Leia docs/00-visao-geral-e-retomada.md, README.md e docs/11-modo-de-execucao-claude.md.

Use somente a interface restrita api.* do Supabase; não acesse tabelas public diretamente. Todos os workflows devem ser importados com active=false. Não use esperas longas como fonte de estado e não crie polling frequente. O Supabase é a fonte oficial de filas e estados.

O canal de WhatsApp é um adaptador abstrato até decisão explícita. Não envie mensagens reais. Entregue testes com dados internal_test e evidência de que payment.paid cancela cobranças antes de pedir QA.
```

### 04 — WhatsApp, IA e atendimento

**Função:** depois da escolha do provedor, implementar o adaptador de envio/recebimento, base de conhecimento, limites da IA e handoff.

**Dona de:** adaptador do canal, `prompts/**`, documentação da base de conhecimento e testes do atendimento.

**Não pode começar implementação do canal:** enquanto o provedor estiver pendente.

**Prompt inicial:**

```text
Você é responsável pelo canal de WhatsApp, IA limitada e atendimento humano do INFORUAN. Leia docs/00-visao-geral-e-retomada.md, docs/07-checklist-base-conhecimento.md e docs/11-modo-de-execucao-claude.md.

Primeiro confirme por escrito qual provedor foi aprovado. Se estiver pendente, trabalhe somente no contrato genérico, na base de conhecimento e nos testes; não instale Evolution, Leona ou Meta direta por suposição.

A IA só responde conteúdo coberto pela base. Fora disso, registra e transfere. Handoff humano: 9h às 20h; fora desse horário, informa o horário e deixa o caso na fila. Use apenas contatos internos até o Gate E2E.
```

### 05 — QA, segurança e release

**Função:** revisar cada entrega, executar testes, comparar com os critérios e autorizar ou bloquear o próximo passo.

**Modo padrão:** somente leitura. Não corrige silenciosamente o trabalho das outras sessões.

**Prompt inicial:**

```text
Você é o Gate de QA e segurança do INFORUAN. Leia docs/00-visao-geral-e-retomada.md e docs/11-modo-de-execucao-claude.md. Revise os commits entregues pelas demais sessões sem implementar mudanças silenciosas.

Para cada gate, confira: escopo, diff, testes, segredos, isolamento, rollback, idempotência, logs sem dados pessoais, nenhuma ativação indevida e evidência de que nenhum cliente real foi afetado. Classifique achados por gravidade e diga APROVADO ou BLOQUEADO.

Só aprove ativação real quando houver teste E2E internal_test, pagamento interrompendo cobrança, observabilidade e autorização expressa do usuário.
```

## Ordem do Crawl

| Ordem | Trabalho | Sessões | Pode ocorrer em paralelo? | Gate de saída |
|---|---|---|---|---|
| 0 | Retomada e reconciliação das decisões | 00 | Não | Fonte oficial e pendências confirmadas |
| 1 | Auditar e preparar a VPS | 01 | 02 pode preparar código local | VPS segura, stack saudável e rollback documentado |
| 2 | Concluir/testar Edge Function da GGCheckout | 02 | Sim, com 01 | Testes locais e revisão da 05 |
| 3 | Conectar n8n à interface restrita do Supabase | 01 + 03 | Após stack pronta | Conectividade sem acesso direto às tabelas |
| 4 | Escolher o provedor de WhatsApp | 00 + usuário | Não delegar decisão | Decisão escrita e requisitos confirmados |
| 5 | Implementar canal, IA limitada e handoff | 04 | 03 pode ajustar contrato, sem envio | Testes internos do adaptador e da IA |
| 6 | Importar workflows inativos | 03 | Sim, após contratos estáveis | Todos `active=false`, configuração validada |
| 7 | Publicar Edge Function e testar E2E interno | 02 + 03 + 04 | Coordenado pela 00 | Gate 05 aprovado; somente `internal_test` |
| 8 | Criar webhook GGCheckout | 02 | Não antes do E2E | Evento real de teste recebido e idempotente |
| 9 | Ativação gradual da recuperação Pix | 00 + 03 | Uma mudança por vez | Holdout 10%, métricas e botão de parada |
| 10 | Pós-compra, IA e handoff | 03 + 04 | Depois da recuperação estável | Operação observada e suporte preparado |

## O que abrir agora

Abra apenas:

1. **00 — Maestro / Torre de controle**
2. **01 — Infraestrutura / Hostinger**

A sessão 02 pode ser aberta quando a 01 terminar a auditoria de leitura e estiver preparando a stack. As sessões 03 e 04 ainda não devem executar integrações. A sessão 05 entra no fim de cada entrega para revisar.

## Regra de passagem entre sessões

Toda sessão de execução encerra sua etapa com este pacote:

1. objetivo realizado;
2. arquivos alterados;
3. commit ou branch;
4. testes e resultado;
5. segredos verificados;
6. ações externas realizadas;
7. o que permanece desligado;
8. rollback;
9. bloqueios;
10. pedido explícito de Gate para a sessão 05.

O Maestro só libera a próxima etapa depois de registrar o resultado do Gate.

## Conflito que deve ser resolvido

`docs/00-visao-geral-e-retomada.md` diz que o provedor de WhatsApp está pendente. Documentos anteriores mencionam Evolution e Leona. Até nova decisão explícita do usuário, vale **provedor pendente**. Nenhuma sessão pode usar os documentos antigos como autorização para instalar ou ativar um canal.
