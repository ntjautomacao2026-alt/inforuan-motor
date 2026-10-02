# Motor de Monetização de Infoprodutos — Proposta de Arquitetura (v0.1)

> Status: **proposta para aprovação**. Nada foi implementado.
> Primeiro caso: e-book do produtor Ruan, vendido via GGCheckout.
> Data: 2026-09-30

---

## 0. Resumo executivo

1. **O motor é um "event store + máquina de estados + fila de ações agendadas"**. Tudo que acontece (webhook, mensagem, clique, resposta) vira um evento normalizado. Regras **determinísticas** transformam eventos em mudanças de estado e em ações agendadas. IA só entra onde há linguagem natural (responder cliente, classificar intenção).
2. **Toda mensagem agendada é revalidada no momento do envio** ("check-before-send"). Pagamento aprovado cancela a fila **e** qualquer envio que escape do cancelamento é barrado pelo guard. Dupla proteção contra o pior erro possível do sistema: cobrar quem já pagou.
3. **Grupo de controle (holdout) desde o dia 1**. Sem isso, "receita recuperada" vai ser superestimada (muita gente paga o Pix de qualquer jeito). É a diferença entre saber e achar que a régua funciona.
4. **O MVP é pequeno e focado em dinheiro**: recuperação (Pix/cartão/abandono) + onboarding + 1 oferta pós-compra + atendente IA no WhatsApp com handoff humano + dashboard de funil/recuperação. Todo o resto é V2/V3.
5. **Estado não é um campo único no contato.** Um mesmo contato pode ser CLIENTE do e-book e ABANDONO do upsell ao mesmo tempo. Separamos: estágio global do contato, estado por produto, status do pedido e matrículas em sequências.

---

## 1. Análise do projeto

### 1.1 O que existe hoje
Tráfego → oferta → GGCheckout → pagamento → entrega por e-mail. Nenhuma camada própria de dados, nenhuma automação pós-checkout.

Pasta do projeto: vazia (greenfield).

Stack que o operador já usa em outra operação e que pode ser reaproveitada como **conhecimento/ferramental**, não como infraestrutura compartilhada:

| Ferramenta | Uso atual | Relevância aqui |
|---|---|---|
| Supabase (Postgres, sa-east-1) | Projeto de outra operação | Candidato natural para o banco. **Projeto separado** (LGPD e isolamento). |
| n8n | 13 workflows (cobrança, lembretes, WhatsApp) | Útil para integrações periféricas; **não recomendado como núcleo** (ver §8). |
| Evolution API (credencial no n8n) | WhatsApp não oficial | Barato e sem templates, mas com risco de banimento em mensagens ativas. |
| Leona (2 números, Meta Cloud API) | Funis de WhatsApp | Alternativa de inbox/canal oficial. |
| OpenAI (credencial no n8n) | IA | Provedor de LLM possível. |

### 1.2 Onde está o dinheiro (revisado com dados reais, ver [`03-diagnostico-conta.md`](03-diagnostico-conta.md))

Setembro: ~6.300 vendas, R$ 268 mil, ticket de R$ 42,6, 90% Pix, 97% do tráfego vindo do Meta. Há duas linhas de produto (Finanças 40+ e Atualiza 40+), com bumps convertendo 37–45%.

1. **Upsell one-click pós-compra (nativo da GGCheckout)**: hoje é **zero**. Existe produto pronto (Consultor R$ 47 e o kit da outra linha). É a maior alavanca, e é configuração, não código. Estimativa: R$ 16–30 mil/mês.
2. **Cross-sell para a base**: ~6 mil compradores, e só 224 compraram as duas linhas.
3. **Recuperação de Pix não pago**: 17% dos pedidos (R$ 57 mil em 5 semanas), quase todos com telefone e e-mail. 15% voltam sozinhos, então o ganho real é o **incremental**. Estimativa: R$ 4–7 mil/mês.
4. **Onboarding**: reduz reembolso e suporte ("não recebi o acesso").
5. **Atendimento IA**: dúvidas pré-compra e suporte.
6. Checkout abandonado antes do Pix: volume desconhecido, só mensurável depois de ligar o webhook.
7. ~~Cartão recusado~~: 98% de aprovação, volume irrelevante. ~~Boleto~~: não é usado. **Saem do MVP.**

---

## 2. Lacunas

| Lacuna | Impacto | Como fechar |
|---|---|---|
| Não há segundo produto/oferta para upsell/cross-sell | Motor de monetização sem o que monetizar após a compra | Definir ao menos 1 oferta complementar (pode ser produto simples: checklist, planilha, aula, comunidade) |
| Não sabemos volume/ticket/margem atuais | Impossível dimensionar custo de WhatsApp/IA vs. receita recuperada, e tamanho de amostra para A/B | Exportar histórico da GGCheckout (últimos 90 dias) |
| Investimento em mídia não está conectado | Sem CAC/ROAS reais | Integração Meta Ads (gasto por campanha/anúncio) ou input manual no MVP |
| Sem base de conhecimento do produto | Agente IA vai alucinar | FAQ, política de reembolso, sumário do e-book, objeções conhecidas |
| Sem consentimento explícito de marketing no checkout | Risco LGPD e política do WhatsApp | Verificar o que a GGCheckout coleta; separar mensagens transacionais de marketing |
| Sem identidade unificada do cliente | Mesma pessoa com e-mails/telefones diferentes | Resolução de identidade por e-mail + telefone E.164 + CPF (hash) |
| Sem definição de "venda recuperada" | Cada um mede de um jeito; números inflados | Definição formal em §12 + holdout |

---

## 3. Riscos

| # | Risco | Prob. | Impacto | Mitigação |
|---|---|---|---|---|
| R1 | Mensagem de cobrança enviada para quem já pagou | Média | Alto (reputação, reembolso, denúncia) | Cancelamento no evento + guard no envio + primeira mensagem nunca antes de T+10min + reconciliação |
| R2 | Webhooks duplicados, fora de ordem ou perdidos | Alta | Alto | Inbox de webhooks cru, dedupe por chave, transições monotônicas (pago nunca volta a pendente), job de reconciliação se houver API |
| R3 | GGCheckout não expõe algum evento (ex.: abandono, Pix expirado) | Ver §5 | Médio | Derivar por timer (pix_generated + validade) ou capturar lead antes do checkout |
| R4 | Banimento do número WhatsApp (API não oficial) | Alta em volume | Alto | API oficial (Meta Cloud) para mensagens ativas; não oficial só como fallback/testes |
| R5 | Custo por mensagem (templates de marketing da Meta) + LLM maior que a margem recuperada num ticket baixo | Média | Médio | Calcular unit economics por régua; limitar toques; e-mail primeiro onde funcionar |
| R6 | "Receita recuperada" inflada (quem pagaria de qualquer jeito) | Certa sem holdout | Alto (decisões erradas) | Holdout de 10–20% por régua; medir lift incremental |
| R7 | Desconto na recuperação treina o cliente a abandonar | Média | Médio (margem) | Preferir bônus/urgência a desconto; testar desconto como variante com holdout |
| R8 | Volume baixo → A/B nunca atinge significância | Alta no início | Médio | Poucos testes de alto impacto, análise bayesiana, testes sequenciais, não testar cor de botão |
| R9 | Agente IA promete o que não existe (preço, bônus, prazo) | Média | Alto | Ofertas só via ferramenta que lê config; proibido inventar; handoff em reembolso/jurídico/irritação |
| R10 | LGPD (dados pessoais + marketing) | Média | Alto | Base legal por tipo de mensagem, opt-out em 1 clique/palavra, log de consentimento, retenção definida |
| R11 | Dependência da GGCheckout (plataforma nova, reclamações públicas) | Média | Médio | Adapter por fonte; modelo interno agnóstico de checkout |
| R12 | Excesso de escopo antes de gerar receita | Alta | Alto | MVP enxuto; toda feature responde a uma das 6 perguntas do briefing |
| R13 | Pressão de upsell aumenta reembolso (garantia de 7 dias, CDC art. 49) | Baixa/Média | Médio | Medir reembolso por variante de oferta; upsell só após consumo/engajamento |

---

## 4. Dependências

**Bloqueantes para o MVP**
- Acesso ao painel GGCheckout (configurar webhook, token de API se houver, exportar histórico).
- Número de WhatsApp dedicado ao produto + Meta Business verificado + templates aprovados (a aprovação leva de horas a dias; começar cedo).
- Domínio de e-mail com SPF/DKIM/DMARC + provedor (Resend, SES ou similar).
- Conteúdo: FAQ, política de reembolso, textos iniciais das réguas, oferta pós-compra.
- Chave de LLM.
- Hospedagem (Supabase + função serverless ou pequeno serviço Node).

**Não bloqueantes (V2)**
- Meta Ads API (gasto, públicos personalizados, CAPI).
- Área de membros com eventos de consumo (sem isso, "consumo" é inferido por cliques/respostas).

---

## 5. Integração GGCheckout

Detalhes, payloads e fontes em [`02-ggcheckout.md`](02-ggcheckout.md). Impacto na arquitetura:

- **Eventos disponíveis** [C]: `pix.generated|paid|expired|failed|refunded` e `card.generated|pending|paid|failed|expired|refunded`, além de "Novo lead" (checkout iniciado; nome técnico a confirmar). Chargeback aparece como status. Boleto e assinatura não estão documentados.
- **API REST existe** (não documentada formalmente): pagamentos paginados, detalhe, verificação no gateway e progresso de alunos. → **Reconciliação e enriquecimento entram no MVP.**
- **Webhook pobre, API rica**: validade do Pix, taxas, cupom e vínculo de upsell só vêm pela API. → O adapter enriquece cada evento.
- **Recursos nativos que se sobrepõem**: recuperação de Pix via WhatsApp, order bump, upsell/downsell one-click, CAPI, área de membros. → O motor **orquestra e mede**, não reconstrói. Upsell one-click fica no checkout; o motor faz o follow-up de quem recusou.
- **Confiabilidade**: 3 retentativas, 7 dias de histórico, dois esquemas de evento conflitantes nas fontes, unidades mistas. → Idempotência, reconciliação a cada 5–10 min e normalização para centavos.

---

## 6. Arquitetura proposta

```
                   ┌──────────────────────────── FONTES ─────────────────────────────┐
                   │ GGCheckout webhooks │ WhatsApp inbound/status │ E-mail status │ Ads│
                   └──────────┬──────────────────────┬─────────────────────┬────────┘
                              ▼                      ▼                     ▼
                   ┌──────────────────────────────────────────────────────────────┐
  1. INGESTÃO      │ Endpoint HTTP: valida assinatura → grava RAW → responde 200   │
                   └──────────┬───────────────────────────────────────────────────┘
                              ▼
  2. NORMALIZAÇÃO  Adapter por fonte → evento canônico (order.pix_generated, ...)
                   Dedupe (idempotency key) · resolução de identidade (contact_id)
                              ▼
  3. EVENT STORE   Tabela append-only `events` (fonte da verdade da jornada)
                              ▼
  4. MOTOR DE      Regras determinísticas (config no banco):
     REGRAS          • transições de estado (contato / produto / pedido)
                     • matrícula em sequências (enroll) e saída (exit)
                     • cancelamento de ações agendadas
                     • atribuição de variante de experimento (sticky)
                              ▼
  5. FILA          `scheduled_actions` (due_at, status). Postgres é a fila.
                              ▼
  6. DISPATCHER    A cada minuto: pega vencidas (SKIP LOCKED) → GUARD:
                     estado ainda permite? pedido ainda não pago? opt-out?
                     horário silencioso? limite de frequência? holdout?
                   → renderiza template/variante → canal
                              ▼
  7. CANAIS        WhatsApp (Meta Cloud) · E-mail · Públicos de anúncio · (futuro)
                   Status de entrega/leitura voltam como eventos (loop)

  8. CONVERSAS     Mensagem inbound → Roteador determinístico (contexto + estado)
                   → Classificador de intenção (LLM barato) → Agente (LLM + tools)
                   → resposta | ação | handoff humano

  9. ANALYTICS     Views/materialized views no Postgres → dashboard
```

### Princípios
- **Postgres é a fonte da verdade e a fila.** Nada de estado escondido dentro de "Wait" de ferramenta de automação.
- **Idempotência em tudo.** Reprocessar o mesmo webhook 10 vezes produz o mesmo resultado.
- **Configuração em dados, não em código.** Produtos, ofertas, esteiras, sequências, passos, templates, experimentos e agentes são linhas no banco, versionadas.
- **Adapters nas bordas.** Trocar GGCheckout por Kiwify/Hotmart, ou Meta Cloud por outro provedor, é escrever um adapter, não reescrever o motor.
- **Multi-tenant barato desde o início.** Toda tabela tem `workspace_id`. Custa quase nada agora e evita migração se o motor atender outros produtores.

---

## 7. Máquina de estados

Quatro camadas independentes, cada uma com transições explícitas.

### 7.1 Status do pedido (`orders.status`), dirigido pelo checkout
```
created ──► pending_payment ──► paid ──► refunded
   │              │               └────► chargeback
   │              ├──► expired      (Pix/boleto venceu)
   │              └──► failed       (cartão recusado)
   └──► abandoned                   (checkout iniciado sem pedido gerado)
```
Regra de monotonicidade: `paid`, `refunded` e `chargeback` são terminais para fins de recuperação. Evento atrasado de `pending` após `paid` é registrado e **ignorado** para transição.

### 7.2 Estado do contato por produto (`contact_product_state`)
```
PROSPECT → CHECKOUT_STARTED → PAYMENT_PENDING → PURCHASED → ONBOARDING → ACTIVE
                 │                  │                                      │
                 ▼                  ▼                                      ▼
             ABANDONED      PAYMENT_FAILED / EXPIRED                 (consumo baixo)
                 │                  │                                  DORMANT
                 └──── (compra) ────┴──────────► PURCHASED
PURCHASED/ACTIVE → REFUNDED | CHARGEBACK
```

### 7.3 Estágio global do contato (`contacts.lifecycle_stage`), derivado
`LEAD → CUSTOMER → REPEAT_CUSTOMER → INACTIVE` (+ flags: `refunded_ever`, `chargeback_ever`, `opted_out_whatsapp`, `opted_out_email`, `blocked`).
Elegibilidade (ex.: `UPSELL_ELIGIBLE`) **não é estado**, é uma regra avaliada sob demanda. Evita estados combinatórios.

### 7.4 Matrícula em sequência (`enrollments.status`)
`active → completed | exited(reason) | cancelled`

### 7.5 Regras de sistema (determinísticas, nunca LLM)

| Evento | Ações |
|---|---|
| `order.paid` | Sair de **todas** as sequências de recuperação do contato para aquele produto (e do pedido); cancelar `scheduled_actions` pendentes; estado → PURCHASED; matricular em onboarding; agendar oferta pós-compra conforme esteira |
| `order.pix_generated` | Matricular em `recovery.pix`. Agendar timer de expiração em `expiresAt` (hoje 15 min) |
| timer `expiresAt` sem `order.paid` | Emitir `order.pix_expired` **pelo próprio motor**. O webhook da GGCheckout só disparou em 68% dos casos. Régua segue com **novo link de checkout** |
| `order.pix_expired` (webhook) | Idempotente com o timer: se já expirado, ignora |
| `order.card_declined` | Matricular em `recovery.card` |
| `checkout.abandoned` | Matricular em `recovery.abandoned` (se não houver pedido pendente/pago) |
| `order.refunded` / `order.chargeback` | Sair de tudo que é comercial; bloquear ofertas; marcar flag; alertar |
| `contact.opted_out` | Cancelar tudo no canal; suprimir |
| `message.inbound` | Pausar régua ativa por N horas (humano/IA está conversando) |

Prioridade entre sequências: um contato recebe **no máximo 1 régua comercial ativa por vez** (a de maior prioridade), com limite global de mensagens por dia.

---

## 8. Módulos

| Módulo | Responsabilidade | Pergunta de negócio que responde |
|---|---|---|
| `ingest` | Receber webhooks, validar, gravar cru, responder rápido | Dados confiáveis |
| `adapters/*` | GGCheckout, WhatsApp, e-mail, Meta Ads → eventos canônicos | Dados / reduz lock-in |
| `identity` | Unificar contato por e-mail/telefone/CPF | Dados (LTV real) |
| `events` | Event store + consultas de jornada | Dados |
| `rules` | Transições de estado, enroll/exit, cancelamentos | Conversão, operação |
| `scheduler` + `dispatcher` | Fila, guard, janelas de horário, frequency cap | Conversão sem prejudicar marca |
| `catalog` | Produtos, ofertas, esteiras, links de checkout | Receita, AOV, LTV |
| `sequences` | Réguas, passos, templates, variantes | Conversão, recuperação |
| `experiments` | Alocação sticky, holdout, leitura de resultados | Dados para decisão |
| `channels/*` | WhatsApp, e-mail, públicos | Conversão |
| `conversations` + `agents` | Inbox, roteamento, IA, handoff | Conversão, operação |
| `attribution` | Qual toque/variante gerou a receita | Dados |
| `analytics` | Views e dashboard | Dados |
| `admin` | CRUD de configuração (MVP: SQL/seed; V2: UI) | Operação |

### Stack recomendada
- **Banco/fila**: Supabase Postgres (projeto novo). `pg_cron` para o dispatcher, `FOR UPDATE SKIP LOCKED` para concorrência.
- **Núcleo**: TypeScript (Supabase Edge Functions ou serviço Node pequeno). Código versionado, testável e com testes de regras críticas (ex.: "pago nunca recebe cobrança").
- **n8n**: opcional, para integrações periféricas e protótipos rápidos. **Não** para o núcleo: Wait nodes não são canceláveis de forma confiável, lógica espalhada em nós é difícil de testar e versionar, e o risco R1 depende exatamente dessas garantias.
- **Dashboard**: MVP com Metabase (ou Looker Studio) em cima das views; V2 dashboard próprio se necessário.
- **LLM**: modelo pequeno/barato para classificação de intenção; modelo mais capaz para respostas do agente. Provedor configurável.

---

## 9. Banco de dados (modelo lógico)

> Campos principais. Todas as tabelas têm `id uuid`, `workspace_id`, `created_at`, `updated_at`.

### Catálogo
- **products**: `name, type (ebook|course|mentoring|community|subscription|bump), status, delivery_type, default_currency, external_ids jsonb`
- **offers**: `product_id, name, role (front|bump|upsell|downsell|cross_sell|winback), price_cents, compare_at_cents, checkout_url, external_offer_id, source (ggcheckout), active`
- **ladders** (esteiras): `name, entry_product_id, active, version`
- **ladder_steps**: `ladder_id, from_product_id, offer_id, trigger (event|delay|condition), delay_minutes, conditions jsonb, priority`

### Contatos e identidade
- **contacts**: `name, email_norm, phone_e164, cpf_hash, lifecycle_stage, first_seen_at, first_utm jsonb, last_utm jsonb, total_revenue_cents, total_orders, flags jsonb`
- **contact_identities**: `contact_id, kind (email|phone|cpf|external), value, source, verified`
- **consents**: `contact_id, channel, purpose (transactional|marketing), status, source, captured_at, evidence jsonb`
- **contact_product_state**: `contact_id, product_id, state, since, last_event_id`
- **state_transitions**: `entity_type, entity_id, from_state, to_state, event_id, at`

### Pedidos e dinheiro
- **checkouts**: `external_checkout_id, contact_id, offer_id, status, started_at, abandoned_at, checkout_url, utm_* , src, sck`
- **orders**: `external_order_id, checkout_id, contact_id, offer_id, product_id, parent_order_id (upsell/bump), status, payment_method, installments, amount_gross_cents, discount_cents, fees_cents, amount_net_cents, coupon, pix_expires_at, pix_code_ref, paid_at, refunded_at, chargeback_at, utm_source, utm_medium, utm_campaign, utm_content, utm_term, src, sck, raw_last jsonb`
- **order_items**: `order_id, offer_id, product_id, role (main|bump), amount_cents`

### Eventos
- **webhook_inbox**: `source, dedupe_key (unique), headers jsonb, payload jsonb, signature_ok, received_at, processed_at, error, attempts`
- **events**: `type, occurred_at, received_at, source, contact_id, product_id, offer_id, order_id, checkout_id, enrollment_id, message_id, agent, payload jsonb, correlation_id, causation_id`. Append-only, índice por `(contact_id, occurred_at)` e `(type, occurred_at)`.

### Automação
- **sequences**: `key (recovery.pix, onboarding.ebook, ...), name, product_id nullable, trigger_event, entry_conditions jsonb, exit_events text[], priority, max_active_per_contact, version, active`
- **sequence_steps**: `sequence_id, position, delay_minutes (relativo ao início ou ao passo anterior), channel, template_key, send_window jsonb (ex.: 08–21h), conditions jsonb, offer_id nullable`
- **templates**: `key, channel, locale, provider_template_name (WhatsApp), body, variables jsonb, category (utility|marketing)`
- **enrollments**: `contact_id, sequence_id, sequence_version, order_id, checkout_id, status, exit_reason, experiment_assignments jsonb, is_holdout, started_at, ended_at`
- **scheduled_actions**: `enrollment_id, step_id, contact_id, due_at, status (pending|processing|sent|skipped|cancelled|failed), skip_reason, attempts, locked_at`

### Mensagens e conversas
- **messages**: `contact_id, conversation_id, channel, direction, enrollment_id, step_id, template_key, variant_key, agent, provider, provider_message_id, status (queued|sent|delivered|read|failed|replied), cost_cents, sent_at, content_hash`
- **conversations**: `contact_id, channel, status (bot|human|closed), assigned_agent, assigned_user, last_inbound_at, window_expires_at`
- **agent_runs**: `conversation_id, agent, intent, input_ref, tools_called jsonb, output, model, tokens_in, tokens_out, cost_cents, latency_ms, escalated, escalation_reason`
- **knowledge_chunks**: `product_id, source, content, embedding vector`

### Experimentos e atribuição
- **experiments**: `key, hypothesis, unit (contact|order|enrollment), scope (sequence_id|offer_id|...), primary_metric, guardrail_metrics, status, started_at, ended_at, min_sample`
- **experiment_variants**: `experiment_id, key, weight, is_control, is_holdout, overrides jsonb`
- **experiment_assignments**: `experiment_id, unit_id, variant_id, assigned_at` (unique `experiment_id, unit_id`)
- **attributions**: `order_id, model (last_touch_72h|first_touch|linear), touch_type (utm|message|enrollment), touch_id, variant_id, weight`

### Mídia
- **ad_spend_daily**: `date, platform, account_id, campaign_id, adset_id, ad_id, spend_cents, impressions, clicks, utm_campaign, utm_content`

### Views de analytics (exemplos)
`v_funnel_daily`, `v_recovery_by_sequence`, `v_recovery_by_channel`, `v_experiment_results`, `v_cohort_ltv`, `v_product_ladder_take_rate`, `v_unit_economics`.

---

## 10. Estratégia de agentes

### 10.1 O "Orquestrador" não é um LLM
É o motor de regras + roteador. Ele identifica contato, produto, histórico, estado, evento, sequência ativa e próxima ação **de forma determinística**. Isso é mais barato, auditável e não erra o básico.

### 10.2 Onde a IA entra
Somente em **mensagens de entrada** (o cliente escreveu algo) e, opcionalmente em V2, em personalização de copy.

```
inbound msg
  → contexto determinístico (estado do contato, pedidos, régua ativa, últimas mensagens)
  → regras rápidas: "SAIR/PARAR" = opt-out; comprovante/imagem = handoff; etc.
  → classificador de intenção (LLM barato): pre_sale_question | objection | payment_issue
     | access_issue | product_question | refund_request | complaint | feedback | other
  → roteia para "persona" de agente
```

### 10.3 Agentes = 1 runtime, N personas
Tecnicamente é o mesmo executor com **system prompt, ferramentas e limites diferentes** por persona. Evita 5 sistemas.

| Persona | Quando | Ferramentas permitidas | Nunca pode |
|---|---|---|---|
| Comercial | Pré-compra, objeção, pagamento pendente/falho | `get_offer`, `get_checkout_link`, `get_order_status`, `apply_approved_incentive` (só os da config) | Inventar preço, desconto ou bônus |
| Suporte | Acesso, entrega, dúvida do produto | `get_order_status`, `resend_access`, `search_knowledge` | Prometer reembolso |
| Pós-venda | Onboarding, feedback | `search_knowledge`, `record_feedback` | Vender antes do consumo |
| Retenção | Upsell/cross-sell/winback | `get_eligible_offers`, `get_checkout_link` | Ofertar para quem tem reembolso/chargeback |
| **Humano** | Reembolso, raiva, jurídico, baixa confiança, 2 falhas seguidas | — | — |

**Guardrails**: ofertas e preços só vêm de ferramentas que leem a config; toda resposta tem `confidence`; abaixo do limiar, handoff; log completo em `agent_runs`.

### 10.4 Recomendação para o MVP
**Um único agente** (Comercial + Suporte) com handoff humano. Para um e-book, volume de suporte é baixo e o ganho está em responder rápido à dúvida pré-compra e ao "não recebi". Pós-venda e retenção no MVP são **réguas determinísticas**, não agentes.

---

## 11. MVP / V2 / V3

### MVP (meta: 3–4 semanas de construção após aprovação)
| Item | Por quê |
|---|---|
| Ingestão GGCheckout + enriquecimento via API + reconciliação a cada 5–10 min + backfill de 90 dias | Base de tudo; cobre webhooks perdidos |
| Event store + identidade | Base de tudo |
| Máquina de estados + regras de sistema (§7.5) | Garantias críticas |
| Régua de Pix não pago (configurável; padrão inicial: T+6 min com o Pix ainda válido → T+20 min novo link → T+3 h → T+24 h → T+72 h, janela 7h–21h) | Recuperar vendas |
| Régua de checkout abandonado (se o evento "Novo lead" trouxer contato) | Recuperar vendas |
| Importação da base histórica via CSV do painel (a API mascara contato) | Cross-sell para ~6 mil compradores |
| Canais: WhatsApp oficial + e-mail | Alcance |
| Onboarding pós-compra (acesso + primeiro passo) | Menos reembolso e suporte |
| Order bump + upsell one-click **nativos da GGCheckout** (configurados, não construídos) + follow-up do motor para quem recusou | AOV/LTV |
| Holdout por régua + A/B de copy/timing (1 teste por vez) | Dados reais |
| Atendente IA (comercial+suporte) com handoff | Conversão e operação |
| Dashboard: funil, recuperação (bruta e incremental), receita por sequência/canal/variante, reembolso | Decisão |
| Gasto de mídia via input manual/CSV diário | CAC/ROAS aproximados |
| Configuração via seed/SQL (sem UI) | Velocidade |
| Registro manual de reembolso (gera `order.refunded` com `source=manual`) | Reembolsos são feitos fora da GGCheckout; sem isso o cliente reembolsado continua recebendo oferta |

### V2
- Integração Meta Ads (gasto automático e públicos personalizados por estágio). CAPI já é nativa da GGCheckout.
- Sinais de consumo via API da área de membros (primeiro acesso e progresso) → onboarding adaptativo e upsell por engajamento.
- Esteiras configuráveis completas (múltiplos produtos, downsell, cadeia de ofertas).
- UI de administração (produtos, réguas, templates, experimentos).
- Agentes Pós-venda e Retenção; coleta de feedback/NPS.
- Winback e recompra; coortes de LTV; reconciliação automática via API.
- Múltiplos produtos em teste simultâneo.

### V3
- Multi-produtor (SaaS/agência) com isolamento por workspace.
- Assinatura/recorrência (dunning).
- Score de propensão (quem recuperar, quando, por qual canal).
- Otimização automática (multi-armed bandit) de timing/canal/copy.
- Novos canais: SMS, Instagram DM, push.

---

## 12. Métricas (definições formais)

| Métrica | Definição |
|---|---|
| Conversão de checkout | pedidos pagos / checkouts iniciados (por oferta, período, UTM) |
| Taxa de abandono | checkouts sem pedido pago em 72h / checkouts iniciados |
| Taxa de pagamento de Pix | Pix pagos / Pix gerados |
| Venda recuperada (bruta) | pedido pago de contato com matrícula ativa em régua de recuperação **e** ≥1 mensagem enviada antes do pagamento, dentro de 7 dias |
| **Venda recuperada incremental** | (taxa de pagamento tratados − taxa de pagamento holdout) × nº tratados. **Métrica oficial de desempenho de régua.** |
| Receita recuperada | idem, em receita líquida |
| Recuperação por sequência/canal/variante | incremental por dimensão (com intervalo de confiança) |
| AOV | receita bruta / pedidos principais (incluindo bumps e upsells do mesmo ciclo de 24h) |
| Upsell take rate | compras da oferta / contatos que receberam a oferta |
| Recompra | clientes com ≥2 pedidos pagos de produtos distintos / clientes |
| LTV (coorte) | receita líquida acumulada por cliente em D30/D60/D90/D180, por coorte de primeira compra e origem |
| Reembolso / chargeback | valor e quantidade / vendas do período (por produto, oferta e variante) |
| CAC | gasto de mídia / novos clientes (pagos) |
| CAC efetivo | gasto de mídia / (novos clientes, incluindo os recuperados) |
| Margem de contribuição | receita líquida − taxas do gateway/plataforma − reembolsos − chargebacks − custo de mensagens − custo de IA − mídia |
| ROAS | receita bruta / gasto de mídia |
| ROI | margem de contribuição / gasto de mídia |
| Custo por venda recuperada | (custo de mensagens + IA da régua) / vendas recuperadas incrementais |

---

## 13. Experimentação

- **Unidade de alocação**: contato (padrão) ou pedido; alocação **sticky** gravada em `experiment_assignments` no momento da matrícula.
- **Holdout permanente**: 10–20% de cada régua de recuperação não recebe mensagem. Reduz com o tempo quando o lift estiver estabelecido (nunca a zero: 5% para monitorar).
- **Variantes como overrides de config**: uma variante muda template, delay, canal, oferta, incentivo ou número de passos, sem código novo.
- **Métrica primária** por experimento (ex.: receita líquida por contato matriculado) + **guardrails** (reembolso, opt-out, bloqueio de número).
- **Um experimento por régua por vez** enquanto o volume for baixo.
- **Leitura**: bayesiana (probabilidade de ser melhor + perda esperada), com amostra mínima pré-definida. Não parar teste no primeiro dia bom.
- **Atribuição**: toda venda carrega `enrollment_id` e `variant_id` do toque; a comparação de variantes é sempre **por intenção de tratar** (todos os matriculados), não só por quem clicou.
- **Registro**: cada experimento tem hipótese, métrica, amostra mínima e decisão documentada ao encerrar.

Backlog inicial de testes (ordem por impacto esperado):
1. Holdout vs. régua Pix (prova de valor).
2. Timing do 1º toque do Pix (10 vs. 30 min).
3. WhatsApp vs. e-mail vs. ambos na régua de abandono.
4. Bônus vs. desconto vs. nada no último toque.
5. Oferta pós-compra: imediata (D0) vs. após consumo (D2).

---

## 14. Perguntas em aberto

Respondidas pelos dados: volume/ticket/Pix (§1.2), recuperação nativa (inativa), existência de produtos para esteira (sim).

1. **Quick win antes do motor**: migrar o upsell do Consultor (hoje um checkout separado sem campos, take rate ~3,7%) para o upsell nativo da GGCheckout, testando lado a lado? E oferecer o Consultor ou outro upsell também na linha Atualiza?
2. **Vazamento de entrega**: o Kit Básico entrega a mesma pasta do Drive que o Completo e os bumps. É intencional?
3. WhatsApp: número novo na API oficial da Meta (recomendado) ou Evolution/WAHA?
4. Núcleo em código (TypeScript + Supabase, recomendado) ou em n8n?
5. Escopo: só produtos do Ruan, ou outros produtores?
7. Gasto de mídia: acesso à conta de anúncios Meta (leitura) ou input manual?
8. Quem atende o handoff humano, e em que horário?
