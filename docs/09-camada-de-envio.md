# Camada única de mensageria (transporte desacoplado)

> Decisão (30/09): transporte inicial = **Evolution API via QR Code** no número novo do INFORUAN. O mesmo número fica conectado ao **Leona só para a coexistência oficial da Meta** (WhatsApp Business no celular). O Leona **não** executa automação nem é fonte de dados.
> Núcleo: **Supabase + n8n**. Troca futura para a **Cloud API oficial** sem reconstruir recuperação, pós-venda ou atendimento.
> Escopo do número nesta fase: **recuperação de checkout, pós-venda e suporte de compras**. **Proibido disparo geral para a base.**

---

## 1. Princípio

As regras comerciais **nunca falam com o provedor**. Elas só chamam:

```
enqueue_message(purpose, contact_id, template_key, variables, idempotency_key, guard, ttl)
```

Todo o resto (fila, limites, pausa, retentativa, renderização, provedor, status) é a camada de envio. Trocar Evolution por Cloud API = trocar o **adapter** e a **renderização do template**. Régua, pós-venda e IA não mudam.

```
 Regras (apply_event, régua, pós-venda, IA)
          │ enqueue_message()            ← única porta de saída
          ▼
 ┌──────────────── Supabase ────────────────┐
 │ outbound_messages (outbox)                │
 │ message_templates (render por provedor)   │
 │ provider_instances (estado, pausa, limite)│
 │ message_status_events (append-only)       │
 │ messages (in/out unificado)               │
 └───────────────────────────────────────────┘
          │ claim_outbound_batch()  [SKIP LOCKED + guard + TTL + instância ok]
          ▼
 n8n WF-SEND (worker)  ──► sub-workflow adapter:  send_evolution  |  send_meta_cloud (futuro)
          ▲                                     
 n8n WF-EVO-IN (webhook Evolution): mensagens recebidas, ecos, acks, conexão
          └──► normaliza → Supabase (messages, status, provider_instances)
```

---

## 2. Tabelas (Supabase)

### `outbound_messages` (outbox)
| Campo | Uso |
|---|---|
| `id`, `workspace_id`, `contact_id`, `to_phone_e164` | Destino |
| `purpose` | `recovery` \| `post_purchase` \| `support` \| `handoff_notice`. **Whitelist no banco**: outro valor é rejeitado |
| `template_key`, `template_version`, `variables jsonb` | Conteúdo lógico (independe do provedor) |
| `rendered_body`, `content_hash` | O que foi de fato enviado (auditoria e casamento de eco) |
| `idempotency_key` **UNIQUE** | Ex.: `recovery:{order_id}:step:{n}`, `post_purchase:{order_id}`, `ai:{inbound_msg_id}` |
| `source_type`, `source_id` | enrollment/step, agent_run, handoff |
| `guard jsonb` | Ex.: `{"order_unpaid": "<order_id>"}`, reavaliado no envio |
| `status` | `queued` → `sending` → `sent` → `delivered` → `read` \| `failed` \| `cancelled` \| `expired` \| `uncertain` \| `dead` |
| `attempts`, `max_attempts` (padrão 3), `next_attempt_at`, `last_error_code` | Retentativa |
| `ttl_at` | Depois disto, **não envia mais** (vira `expired`) |
| `provider`, `provider_instance`, `provider_message_id` **UNIQUE** | Rastreio no provedor |
| `queued_at`, `sent_at`, `delivered_at`, `read_at`, `failed_at` | Linha do tempo |
| `is_internal_test`, `experiment_arm` | Métricas |

### `provider_instances`
`provider` (evolution/meta_cloud), `instance_name`, `phone_e164`, `state` (open/connecting/close), `state_changed_at`, `paused` bool, `pause_reason`, `rate_per_minute`, `min_gap_seconds`, `daily_cap`, `sent_today`, `last_health_check_at`.

### `message_templates`
`key`, `version`, `purpose`, `ttl_minutes`, `body_text` (Evolution: texto com `{{variaveis}}`), `meta_template_name` + `meta_param_order` + `meta_category` (para a migração), `active`.
> **Os textos já nascem no formato de template da Meta** (variáveis numeradas, sem conteúdo proibido). A migração vira só uma submissão para aprovação.

### `messages` (unificado in/out) e `message_status_events`
- `messages`: `direction`, `contact_id`, `conversation_id`, `provider_message_id` **UNIQUE**, `from_me`, `origin` (`engine` | `human_phone` | `human_leona` | `customer`), `type` (text/image/audio/document), `text`, `outbound_id`, `received_at`.
- `message_status_events`: `provider_message_id`, `status`, `raw`, `at` (append-only).

---

## 3. Worker de envio (n8n WF-SEND)

A cada 15 s (cron) ou ao ser acordado pelo enqueue:

1. `claim_outbound_batch(limit)` no Supabase, **numa transação**:
   - só instâncias com `state='open'` e `paused=false`;
   - respeita `rate_per_minute`, `min_gap_seconds` e `daily_cap`;
   - `ttl_at < now()` → `expired` (não envia atrasado);
   - **guard**: `order_unpaid` verifica em `orders` e cancela se estiver pago;
   - opt-out/supressão do contato → `cancelled`;
   - marca `sending`, `attempts+1`.
2. Para `purpose=recovery`: **confirma o status na GGCheckout** (API) antes de enviar; se estiver pago → `cancelled`.
3. Renderiza `template_key` + `variables` para o provedor da instância.
4. Chama o **adapter** (sub-workflow) com um contrato fixo:
   - entrada: `{instance, to, body | media, presence_ms}`
   - saída: `{ok, provider_message_id, retryable, error_code}`
5. Resultado:
   - `ok` → `sent` + `provider_message_id`.
   - erro `retryable` → `queued` com backoff (1 min, 5 min, 15 min) até `max_attempts` → `dead` + alerta.
   - erro não retentável (número inválido, sem WhatsApp) → `failed`.
   - **timeout/resultado desconhecido** → `uncertain` (**não reenvia às cegas**). Por até 3 min o worker procura o eco (`fromMe`) com o mesmo `content_hash` para esse telefone. Se achar, vira `sent`; se não, **uma** retentativa.

### Anti-ban (transporte via QR)
- Envio só para quem **gerou Pix, comprou ou escreveu** para o número (checado no guard).
- Intervalo com variação de 8–20 s entre mensagens; status "digitando" por 2–4 s antes de cada envio; limite inicial de **~6 mensagens/min** e **300/dia**.
- Sem mensagens idênticas em sequência: a variável de nome e as variações de texto quebram o hash.
- Palavras de opt-out ("parar", "sair", "não quero") → supressão imediata.
- Link só a partir da 2ª mensagem da régua (a 1ª tem o código Pix, sem link).

---

## 4. Pausa automática quando a instância cai

| Fonte | Ação |
|---|---|
| Webhook `CONNECTION_UPDATE` da Evolution | Atualiza `provider_instances.state`. Se diferente de `open` → `paused=true`, `pause_reason='disconnected'` |
| Health check (cron 1 min, `connectionState`) | Mesma regra. Cobre o caso de o webhook de desconexão não chegar |
| Falhas seguidas (≥ 3 erros de envio em 5 min) | `paused=true`, `pause_reason='error_burst'` |

- Com a instância pausada, a fila **acumula** e nada se perde. Na reconexão, cada mensagem passa de novo pelo guard e pelo TTL. Exemplo: o "Pix ainda válido" (TTL 8 min) expira em vez de chegar atrasado.
- **Alerta de desconexão por um canal que não seja o próprio WhatsApp** (e-mail ou Telegram da equipe), porque o número está fora.
- Despausar: automático na reconexão (se o motivo for `disconnected`) ou manual (se for `error_burst`).

---

## 5. Entrada (n8n WF-EVO-IN)

Webhook da Evolution → valida o segredo/apikey → grava bruto em `webhook_inbox` (dedupe por `provider_message_id` + tipo de evento) → responde 200 → processa separado:

| Evento Evolution | Tratamento |
|---|---|
| `MESSAGES_UPSERT`, `fromMe=false` | Mensagem do cliente → `messages` (origin=`customer`) → pausa a régua do contato → vai para o atendimento IA (ou para o humano, se a conversa estiver em modo humano) |
| `MESSAGES_UPSERT`, `fromMe=true`, **id existe na outbox** | Eco do motor → confirma `sent` |
| `MESSAGES_UPSERT`, `fromMe=true`, **id NÃO existe na outbox** | **Um humano respondeu** (celular/app ou Leona) → `origin=human_*` → conversa entra em **modo humano**: a IA para de responder naquele contato |
| `MESSAGES_UPDATE` (acks) | `delivered` / `read` → `message_status_events` + outbox |
| `CONNECTION_UPDATE` | §4 |
| Grupos, `status@broadcast`, newsletters | Ignorados |

---

## 6. Handoff humano com este transporte

- **Inbox humana = WhatsApp Business no celular** (e/ou a inbox do Leona via coexistência, **só para ler e responder manualmente**).
- Handoff no motor = `conversations.mode='human'` + registro em `handoffs` + aviso à equipe:
  - **9h–20h**: aviso imediato à equipe (canal interno) com resumo e link `wa.me`.
  - **Fora do horário**: a IA responde com o horário, registra `queued` e avisa a equipe às 9h.
- Volta para a IA: automática após **12 h sem mensagem humana**, ou manual (comando interno/etiqueta, a definir).
- A detecção de resposta humana pelo eco (§5) impede que a IA "atropele" o atendente.

---

## 7. Migração futura para a Cloud API (o que muda)

| Muda | Não muda |
|---|---|
| Adapter `send_meta_cloud` | `enqueue_message`, régua, pós-venda, IA, holdout |
| Renderização → `meta_template_name` + parâmetros (templates submetidos para aprovação) | Tabelas, idempotência, guard, TTL, métricas |
| Webhook de entrada/status da Meta → mesmo normalizador | Handoff (só muda a origem do eco) |
| Janela de 24 h: fora dela, só template aprovado (a camada decide texto livre vs. template) | — |

---

## 8. Servidor Evolution: fase de teste (exceção temporária ao isolamento)

Decisão (30/09): nos primeiros **3 a 5 dias** a instância do INFORUAN roda **no mesmo servidor Evolution da outra operação**; depois migra para um servidor próprio.

Regras para essa convivência:
1. **Instância própria** (ex.: `inforuan-01`), com nome que não colida com a outra operação.
2. O n8n do INFORUAN usa **só o token da instância**, nunca a API key global do servidor. Assim ele não enxerga nem controla instâncias da outra operação.
3. **Webhook configurado por instância**, apontando só para o n8n do INFORUAN.
4. ⚠️ **Verificar antes de conectar o QR**: se o servidor tiver **webhook global** ativo (apontando para o n8n da outra operação), os eventos do número do INFORUAN também iriam para os workflows da outra operação. Isso vazaria dados e poderia fazer a outra operação reagir a clientes do INFORUAN. É preciso desligar o global ou confirmar que o webhook por instância o substitui, e que os workflows da outra operação filtram pela instância deles.
5. Base URL e token da Evolution ficam só na credencial do n8n (`EVOLUTION_BASE_URL` e o token da instância), nunca no código dos workflows. **A troca de servidor = reconectar o QR no servidor novo + trocar a credencial.** Tabelas, fila e workflows não mudam.
6. Na troca: pausar a instância (`paused=true`), deixar a fila acumular, reconectar no servidor novo, testar envio e recebimento, despausar. As mensagens com TTL vencido expiram, e não chegam atrasadas.

## 9. Riscos específicos desta fase

| Risco | Mitigação |
|---|---|
| Banimento do número (cliente não oficial) derruba **também** a coexistência | Limites da §3, só contatos transacionais, aquecimento do número, monitorar bloqueios/denúncias; migrar para a Cloud API assim que validado |
| **O QR da Evolution pode desconectar ao ativar a coexistência** (a Meta pode desvincular aparelhos no onboarding) | **Primeiro teste**: ativar a coexistência → vincular o QR → enviar/receber → confirmar que os dois continuam ativos |
| Fluxo ou agente de IA do Leona respondendo no mesmo número | **Nenhum fluxo/agente ativo** na conta Leona do INFORUAN; checar antes de ligar |
| Mensagem duplicada | `idempotency_key` UNIQUE + `SKIP LOCKED` + estado `uncertain` com casamento de eco |
| Humano e IA respondendo juntos | Modo humano por eco `fromMe` sem outbox |
| Disparo acidental para a base | Whitelist de `purpose` no banco + guard exige vínculo transacional recente |
