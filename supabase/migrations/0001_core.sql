-- INFORUAN — Motor de monetização
-- 0001: tabelas núcleo. Postgres 15+ (Supabase).
-- Convenções: tudo tem workspace_id; timestamps em timestamptz (UTC); valores em centavos.
-- RLS ligado em todas as tabelas SEM policies: só service_role (n8n) acessa.

create table if not exists workspaces (
  id          uuid primary key default gen_random_uuid(),
  slug        text not null unique,
  name        text not null,
  created_at  timestamptz not null default now()
);

create table if not exists settings (
  workspace_id uuid not null references workspaces(id),
  key          text not null,
  value        jsonb not null,
  updated_at   timestamptz not null default now(),
  primary key (workspace_id, key)
);

-- ─── Catálogo (espelho mínimo da GGCheckout) ────────────────────────────────
create table if not exists catalog_products (
  workspace_id        uuid not null references workspaces(id),
  external_product_id text not null,
  title               text not null,
  line                text,                       -- financas | atualiza | golpes | consultor
  access_url          text,                       -- link entregue hoje (pasta legada)
  access_instructions text,
  active              boolean not null default true,
  primary key (workspace_id, external_product_id)
);

create table if not exists catalog_checkouts (
  workspace_id         uuid not null references workspaces(id),
  external_checkout_id text not null,
  external_product_id  text not null,
  title                text,
  public_url           text,                      -- link para "gerar novo Pix"; NULL = régua não envia passos com link
  is_internal_test     boolean not null default false,
  primary key (workspace_id, external_checkout_id)
);

-- ─── Contatos ────────────────────────────────────────────────────────────────
create table if not exists contacts (
  id                    uuid primary key default gen_random_uuid(),
  workspace_id          uuid not null references workspaces(id),
  phone_e164            text,
  email_norm            text,
  name                  text,
  first_seen_at         timestamptz not null default now(),
  is_internal_test      boolean not null default false,
  opted_out_at          timestamptz,              -- supressão total de mensagens do motor
  opted_out_reason      text,
  commercial_blocked_at timestamptz,              -- reembolso/chargeback: sem ofertas
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now()
);
create unique index if not exists contacts_ws_phone_uq on contacts(workspace_id, phone_e164) where phone_e164 is not null;
create index if not exists contacts_ws_email_ix on contacts(workspace_id, email_norm);

-- ─── Pedidos ─────────────────────────────────────────────────────────────────
create table if not exists orders (
  id                   uuid primary key default gen_random_uuid(),
  workspace_id         uuid not null references workspaces(id),
  source               text not null default 'ggcheckout',
  external_id          text not null,             -- payment.id da GGCheckout
  contact_id           uuid references contacts(id),
  external_checkout_id text,
  external_product_id  text,
  offer_title          text,
  status               text not null check (status in ('pending','paid','expired','failed','cancelled','refunded','chargeback')),
  payment_method       text,
  amount_cents         integer,
  currency             text default 'BRL',
  pix_code             text,
  pix_expires_at       timestamptz,
  source_created_at    timestamptz,
  paid_at              timestamptz,
  refunded_at          timestamptz,
  utm                  jsonb not null default '{}',
  is_internal_test     boolean not null default false,
  raw_last             jsonb,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  unique (workspace_id, source, external_id)
);
create index if not exists orders_contact_ix on orders(contact_id, created_at desc);
create index if not exists orders_status_ix on orders(workspace_id, status);

create table if not exists order_items (
  order_id            uuid not null references orders(id) on delete cascade,
  external_product_id text not null,
  title               text,
  role                text not null check (role in ('main','bump','upsell','downsell')),
  amount_cents        integer,
  primary key (order_id, external_product_id)
);

-- ─── Entrada bruta e eventos ─────────────────────────────────────────────────
create table if not exists webhook_inbox (
  id            bigserial primary key,
  workspace_id  uuid not null references workspaces(id),
  source        text not null,                    -- ggcheckout | evolution
  dedupe_key    text not null,
  event_type    text,
  headers       jsonb not null default '{}',      -- já SEM authorization / x-secret / apikey
  payload       jsonb not null,
  received_at   timestamptz not null default now(),
  processed_at  timestamptz,
  attempts      integer not null default 0,
  error         text,
  unique (source, dedupe_key)
);
create index if not exists webhook_inbox_pending_ix on webhook_inbox(received_at) where processed_at is null;

create table if not exists events (
  id           bigserial primary key,
  workspace_id uuid not null references workspaces(id),
  type         text not null,
  occurred_at  timestamptz not null,
  contact_id   uuid references contacts(id),
  order_id     uuid references orders(id),
  source       text not null,
  inbox_id     bigint references webhook_inbox(id),
  payload      jsonb not null default '{}',
  created_at   timestamptz not null default now()
);
create index if not exists events_contact_ix on events(contact_id, occurred_at);
create index if not exists events_type_ix on events(workspace_id, type, occurred_at);

-- ─── Experimentos (holdout) ──────────────────────────────────────────────────
create table if not exists experiments (
  id             uuid primary key default gen_random_uuid(),
  workspace_id   uuid not null references workspaces(id),
  key            text not null,
  status         text not null default 'running' check (status in ('draft','running','stopped')),
  holdout_pct    integer not null check (holdout_pct between 0 and 100),
  salt           text not null,
  window_hours   integer not null default 72,
  eligibility_offset_minutes integer not null default 6,
  primary_metric text not null default 'paid_within_window',
  started_at     timestamptz not null default now(),
  ended_at       timestamptz,
  unique (workspace_id, key)
);

create table if not exists experiment_assignments (
  experiment_id uuid not null references experiments(id),
  contact_id    uuid not null references contacts(id),
  arm           text not null check (arm in ('control','treatment')),
  bucket        integer not null,
  forced        boolean not null default false,   -- contato interno: sempre treatment e fora das métricas
  assigned_at   timestamptz not null default now(),
  primary key (experiment_id, contact_id)
);

-- ─── Réguas ──────────────────────────────────────────────────────────────────
create table if not exists sequences (
  id             uuid primary key default gen_random_uuid(),
  workspace_id   uuid not null references workspaces(id),
  key            text not null,
  purpose        text not null,
  active         boolean not null default false,
  version        integer not null default 1,
  experiment_key text,
  unique (workspace_id, key)
);

create table if not exists sequence_steps (
  id                 uuid primary key default gen_random_uuid(),
  sequence_id        uuid not null references sequences(id),
  position           integer not null,
  delay_minutes      integer not null,            -- a partir da criação do pedido
  template_key       text not null,
  respect_send_window boolean not null default true,
  requires_checkout_url boolean not null default false,
  active             boolean not null default true,
  unique (sequence_id, position)
);

create table if not exists enrollments (
  id           uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references workspaces(id),
  contact_id   uuid not null references contacts(id),
  sequence_id  uuid not null references sequences(id),
  order_id     uuid not null references orders(id),
  status       text not null default 'active' check (status in ('active','completed','exited')),
  exit_reason  text,
  arm          text not null check (arm in ('control','treatment')),
  is_internal_test boolean not null default false,
  eligible_at  timestamptz not null,              -- instante de elegibilidade do holdout (T+offset)
  started_at   timestamptz not null default now(),
  ended_at     timestamptz,
  unique (sequence_id, order_id)
);
create index if not exists enrollments_contact_ix on enrollments(contact_id, status);

create table if not exists scheduled_actions (
  id            uuid primary key default gen_random_uuid(),
  enrollment_id uuid not null references enrollments(id),
  step_id       uuid not null references sequence_steps(id),
  contact_id    uuid not null references contacts(id),
  order_id      uuid not null references orders(id),
  due_at        timestamptz not null,
  status        text not null default 'pending' check (status in ('pending','enqueued','skipped','cancelled')),
  skip_reason   text,
  outbound_id   uuid,
  processed_at  timestamptz,
  unique (enrollment_id, step_id)
);
create index if not exists scheduled_actions_due_ix on scheduled_actions(due_at) where status = 'pending';

-- ─── Mensageria (camada única de envio) ──────────────────────────────────────
create table if not exists message_templates (
  workspace_id       uuid not null references workspaces(id),
  key                text not null,
  version            integer not null default 1,
  purpose            text not null,
  body_text          text not null,              -- Evolution: texto com {{variaveis}}
  ttl_minutes        integer not null,
  required_vars      text[] not null default '{}',
  meta_template_name text,                       -- migração futura p/ Cloud API
  meta_param_order   text[],
  meta_category      text,
  active             boolean not null default true,
  primary key (workspace_id, key, version)
);

create table if not exists provider_instances (
  id                   uuid primary key default gen_random_uuid(),
  workspace_id         uuid not null references workspaces(id),
  provider             text not null check (provider in ('evolution','meta_cloud')),
  instance_name        text not null unique,
  phone_e164           text,
  state                text not null default 'close',   -- open | connecting | close
  state_changed_at     timestamptz not null default now(),
  paused               boolean not null default true,    -- nasce PAUSADA: nada sai até liberar
  pause_reason         text default 'not_activated',
  rate_per_minute      integer not null default 4,
  min_gap_seconds      integer not null default 12,
  daily_cap            integer not null default 150,
  last_claimed_at      timestamptz,
  last_health_check_at timestamptz,
  active               boolean not null default true
);

create table if not exists conversations (
  id               uuid primary key default gen_random_uuid(),
  workspace_id     uuid not null references workspaces(id),
  contact_id       uuid not null unique references contacts(id),
  last_inbound_at  timestamptz,
  last_outbound_at timestamptz,
  ai_pending_since timestamptz,                  -- debounce: IA responde após juntar mensagens
  created_at       timestamptz not null default now()
);

create table if not exists outbound_messages (
  id                  uuid primary key default gen_random_uuid(),
  workspace_id        uuid not null references workspaces(id),
  contact_id          uuid not null references contacts(id),
  to_phone_e164       text not null,
  purpose             text not null check (purpose in ('recovery','post_purchase','support','handoff_notice')),
  template_key        text not null,
  template_version    integer not null,
  variables           jsonb not null default '{}',
  rendered_body       text not null,
  content_hash        text not null,
  idempotency_key     text not null unique,
  source_type         text,
  source_id           text,
  guard               jsonb not null default '{}',
  priority            integer not null default 5,       -- menor = antes
  status              text not null default 'queued' check (status in
                        ('queued','sending','sent','delivered','read','failed','cancelled','expired','uncertain','dead')),
  status_reason       text,
  attempts            integer not null default 0,
  max_attempts        integer not null default 3,
  next_attempt_at     timestamptz not null default now(),
  ttl_at              timestamptz not null,
  provider            text,
  provider_instance   text,
  provider_message_id text unique,
  last_error_code     text,
  is_internal_test    boolean not null default false,
  experiment_arm      text,
  queued_at           timestamptz not null default now(),
  claimed_at          timestamptz,
  sent_at             timestamptz,
  delivered_at        timestamptz,
  read_at             timestamptz,
  failed_at           timestamptz
);
create index if not exists outbound_queue_ix on outbound_messages(priority, queued_at) where status = 'queued';
create index if not exists outbound_contact_ix on outbound_messages(contact_id, queued_at desc);

create table if not exists messages (
  id                  uuid primary key default gen_random_uuid(),
  workspace_id        uuid not null references workspaces(id),
  contact_id          uuid references contacts(id),
  conversation_id     uuid references conversations(id),
  direction           text not null check (direction in ('in','out')),
  provider            text not null,
  provider_instance   text,
  provider_message_id text not null,
  from_me             boolean not null,
  origin              text not null check (origin in ('customer','engine','human_phone')),
  type                text not null,
  text                text,
  outbound_id         uuid references outbound_messages(id),
  occurred_at         timestamptz not null,
  answered_by_ai_at   timestamptz,
  created_at          timestamptz not null default now(),
  unique (provider, provider_message_id)
);
create index if not exists messages_contact_ix on messages(contact_id, occurred_at);

create table if not exists message_status_events (
  id                  bigserial primary key,
  provider            text not null,
  provider_message_id text not null,
  status              text not null,
  at                  timestamptz not null default now(),
  raw                 jsonb
);
create index if not exists msg_status_pmid_ix on message_status_events(provider_message_id);

-- ─── Handoff humano (estado explícito) ───────────────────────────────────────
create table if not exists handoffs (
  id              uuid primary key default gen_random_uuid(),
  workspace_id    uuid not null references workspaces(id),
  contact_id      uuid not null references contacts(id),
  reason          text not null,
  origin          text not null check (origin in ('ai','customer_request','human_reply_detected','manual','non_text_message')),
  status          text not null check (status in ('open','queued','released','expired')),
  started_at      timestamptz not null default now(),
  expires_at      timestamptz not null,
  released_at     timestamptz,
  released_by     text,
  notified_at     timestamptz,
  summary         text
);
create unique index if not exists handoffs_one_active_uq on handoffs(contact_id) where status in ('open','queued');

-- ─── IA ──────────────────────────────────────────────────────────────────────
create table if not exists kb_articles (
  id            uuid primary key default gen_random_uuid(),
  workspace_id  uuid not null references workspaces(id),
  slug          text not null,
  title         text not null,
  answer        text not null,
  product_scope text[] not null default '{}',   -- vazio = vale para todos
  approved_by   text,                            -- só artigos aprovados vão para a IA
  active        boolean not null default false,
  updated_at    timestamptz not null default now(),
  unique (workspace_id, slug)
);

create table if not exists agent_runs (
  id               uuid primary key default gen_random_uuid(),
  workspace_id     uuid not null references workspaces(id),
  contact_id       uuid not null references contacts(id),
  inbound_ids      uuid[] not null,
  decision         text not null check (decision in ('reply','handoff','error')),
  reply_text       text,
  kb_slugs         text[] not null default '{}',
  handoff_reason   text,
  model            text,
  stop_reason      text,
  tokens_in        integer,
  tokens_out       integer,
  latency_ms       integer,
  created_at       timestamptz not null default now()
);

-- ─── Alertas internos (Telegram) ─────────────────────────────────────────────
create table if not exists alerts (
  id           bigserial primary key,
  workspace_id uuid not null references workspaces(id),
  kind         text not null,
  severity     text not null default 'info' check (severity in ('info','warn','critical')),
  text         text not null,                   -- sem dados pessoais além do necessário
  dedupe_key   text,
  created_at   timestamptz not null default now(),
  claimed_at   timestamptz,
  sent_at      timestamptz,
  attempts     integer not null default 0
);
create unique index if not exists alerts_dedupe_uq on alerts(workspace_id, dedupe_key) where dedupe_key is not null;
create index if not exists alerts_pending_ix on alerts(created_at) where sent_at is null;

-- ─── RLS: tudo fechado para anon/authenticated ───────────────────────────────
do $$
declare t text;
begin
  foreach t in array array['workspaces','settings','catalog_products','catalog_checkouts','contacts','orders','order_items',
    'webhook_inbox','events','experiments','experiment_assignments','sequences','sequence_steps','enrollments',
    'scheduled_actions','message_templates','provider_instances','conversations','outbound_messages','messages',
    'message_status_events','handoffs','kb_articles','agent_runs','alerts']
  loop
    execute format('alter table %I enable row level security', t);
  end loop;
end $$;
