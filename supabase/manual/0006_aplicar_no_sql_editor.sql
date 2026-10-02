-- COLE TUDO NO SQL EDITOR DO SUPABASE (projeto bsmuouivezjnfrcnamky) E CLIQUE EM RUN.
-- Conteúdo idêntico a supabase/migrations/0006_api_interface.sql + registro no histórico de migrações.
begin;
-- INFORUAN — 0006: interface restrita do n8n, retenção e heartbeat.
-- • schema `api`: ÚNICA porta do n8n para o motor (wrappers SECURITY DEFINER, search_path fixo, sem p_now).
-- • role `n8n_engine`: NOLOGIN aqui. O login/senha é habilitado manualmente pelo operador (nunca em arquivo).
--   Só EXECUTE nas funções de `api`. Nenhum privilégio em tabelas, visões ou funções de `public`.
-- • retenção de 30 dias dos JSONs brutos (função; agendamento fica para quando o pg_cron for ativado).
-- • heartbeat de serviços (anti-pausa do Supabase Free + monitoramento do n8n).

-- ─── Role restrita ───────────────────────────────────────────────────────────
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'n8n_engine') then
    create role n8n_engine nologin noinherit;
  end if;
end $$;
alter role n8n_engine connection limit 10;

create schema if not exists api;
revoke all on schema api from public;
grant usage on schema api to n8n_engine;

-- ─── Heartbeat ───────────────────────────────────────────────────────────────
create table if not exists service_heartbeats (
  service      text primary key,
  last_seen_at timestamptz not null,
  meta         jsonb not null default '{}'
);
alter table service_heartbeats enable row level security;

create or replace function public.record_heartbeat(p_service text, p_meta jsonb default '{}', p_now timestamptz default now())
returns void language sql as $$
  insert into service_heartbeats(service, last_seen_at, meta) values (p_service, p_now, coalesce(p_meta, '{}'))
  on conflict (service) do update set last_seen_at = excluded.last_seen_at, meta = excluded.meta
$$;

-- ─── Retenção (30 dias por padrão) ───────────────────────────────────────────
create or replace function public.purge_retention(p_days int default 30, p_now timestamptz default now())
returns jsonb language plpgsql as $$
declare cutoff timestamptz := p_now - make_interval(days => p_days); n1 int; n2 int; n3 int; n4 int;
begin
  update webhook_inbox
     set payload = jsonb_build_object('purged_at', p_now, 'event', payload ->> 'event'), headers = '{}'
   where processed_at is not null and received_at < cutoff and not (payload ? 'purged_at');
  get diagnostics n1 = row_count;
  update orders set raw_last = null where raw_last is not null and updated_at < cutoff;
  get diagnostics n2 = row_count;
  update message_status_events set raw = null where raw is not null and at < cutoff;
  get diagnostics n3 = row_count;
  delete from alerts where sent_at is not null and sent_at < cutoff;
  get diagnostics n4 = row_count;
  return jsonb_build_object('inbox_payloads', n1, 'orders_raw', n2, 'status_raw', n3, 'alerts_deleted', n4);
end $$;

-- ─── Vigia: inclui heartbeat do n8n ──────────────────────────────────────────
create or replace function public.watchdog(p_ws_slug text, p_now timestamptz default now())
returns jsonb language plpgsql as $$
declare ws uuid := ws_id(p_ws_slug); tz text := setting_text(ws, 'timezone', 'America/Sao_Paulo'); lt time; n int;
begin
  lt := (p_now at time zone tz)::time;
  if lt between '08:00' and '23:00' and not exists (select 1 from webhook_inbox where workspace_id = ws and source = 'ggcheckout'
       and received_at > p_now - interval '2 hours') and exists (select 1 from webhook_inbox where workspace_id = ws and source = 'ggcheckout') then
    perform raise_alert(ws, 'no_gg_webhooks', 'warn', '⚠️ Nenhum evento da GGCheckout nas últimas 2h. Webhook caiu?',
                        'nogg:' || to_char(p_now, 'YYYYMMDDHH24'));
  end if;
  if exists (select 1 from provider_instances where workspace_id = ws and active
            and (last_health_check_at is null or last_health_check_at < p_now - interval '5 minutes')) then
    perform raise_alert(ws, 'health_stale', 'warn', '⚠️ Health check do WhatsApp sem rodar há mais de 5 min (n8n parado?)',
                        'health:' || to_char(p_now, 'YYYYMMDDHH24'));
  end if;
  if exists (select 1 from service_heartbeats where service = 'n8n' and last_seen_at < p_now - interval '15 minutes') then
    perform raise_alert(ws, 'n8n_heartbeat_stale', 'critical', '🔴 n8n sem sinal de vida há mais de 15 min.',
                        'hb:' || to_char(p_now, 'YYYYMMDDHH24'));
  end if;
  select count(*) into n from outbound_messages where workspace_id = ws and status = 'queued' and queued_at < p_now - interval '15 minutes';
  if n > 0 then
    perform raise_alert(ws, 'queue_stale', 'warn', '⚠️ ' || n || ' mensagens na fila há mais de 15 min.',
                        'qstale:' || to_char(p_now, 'YYYYMMDDHH24'));
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- ─── Interface `api` (o que o n8n pode chamar) ───────────────────────────────
create or replace function api.claim_outbound(p_instance text, p_limit int default 1)
returns setof jsonb language sql security definer set search_path = public, pg_temp as $$
  select to_jsonb(m) from public.claim_outbound(p_instance, p_limit) m
$$;

create or replace function api.mark_outbound_result(p_id uuid, p_ok boolean, p_provider_message_id text default null,
  p_error_code text default null, p_retryable boolean default false, p_uncertain boolean default false)
returns text language sql security definer set search_path = public, pg_temp as $$
  select public.mark_outbound_result(p_id, p_ok, p_provider_message_id, p_error_code, p_retryable, p_uncertain)
$$;

create or replace function api.cancel_outbound(p_id uuid, p_reason text)
returns void language sql security definer set search_path = public, pg_temp as $$
  select public.cancel_outbound(p_id, p_reason)
$$;

create or replace function api.claim_ai_work(p_debounce_seconds int default 20, p_limit int default 5, p_ws_slug text default 'inforuan')
returns setof jsonb language sql security definer set search_path = public, pg_temp as $$
  select public.claim_ai_work(p_ws_slug, p_debounce_seconds, p_limit)
$$;

create or replace function api.record_ai_result(p_contact uuid, p_inbound_ids uuid[], p_decision text, p_reply text,
  p_kb_slugs text[], p_handoff_reason text, p_model text, p_stop_reason text,
  p_tokens_in int, p_tokens_out int, p_latency_ms int, p_ws_slug text default 'inforuan')
returns jsonb language sql security definer set search_path = public, pg_temp as $$
  select public.record_ai_result(p_ws_slug, p_contact, p_inbound_ids, p_decision, p_reply, p_kb_slugs, p_handoff_reason,
                                 p_model, p_stop_reason, p_tokens_in, p_tokens_out, p_latency_ms)
$$;

create or replace function api.claim_alerts(p_limit int default 10)
returns setof jsonb language sql security definer set search_path = public, pg_temp as $$
  select to_jsonb(a) - 'workspace_id' from public.claim_alerts(p_limit) a
$$;

create or replace function api.mark_alert_sent(p_id bigint)
returns void language sql security definer set search_path = public, pg_temp as $$
  select public.mark_alert_sent(p_id)
$$;

create or replace function api.reconcile_gg_batch(p_items jsonb, p_ws_slug text default 'inforuan')
returns jsonb language sql security definer set search_path = public, pg_temp as $$
  select public.reconcile_gg_batch(p_ws_slug, p_items)
$$;

create or replace function api.set_instance_state(p_instance text, p_state text)
returns void language sql security definer set search_path = public, pg_temp as $$
  select public.set_instance_state(p_instance, p_state)
$$;

create or replace function api.heartbeat(p_service text default 'n8n', p_meta jsonb default '{}')
returns void language sql security definer set search_path = public, pg_temp as $$
  select public.record_heartbeat(p_service, p_meta)
$$;

-- ─── Permissões ──────────────────────────────────────────────────────────────
do $$
declare f record;
begin
  -- api: só n8n_engine (e service_role, para testes/operador)
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'api' loop
    execute format('revoke all on function %s from public', f.sig);
    execute format('grant execute on function %s to n8n_engine', f.sig);
    if exists (select 1 from pg_roles where rolname = 'service_role') then
      execute format('grant execute on function %s to service_role', f.sig);
    end if;
  end loop;
  -- public: funções novas seguem o padrão (sem acesso público, search_path fixo)
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname in ('record_heartbeat','purge_retention','watchdog') loop
    execute format('revoke all on function %s from public', f.sig);
    execute format('alter function %s set search_path = public, pg_temp', f.sig);
    if exists (select 1 from pg_roles where rolname = 'service_role') then
      execute format('grant execute on function %s to service_role', f.sig);
    end if;
  end loop;
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on table service_heartbeats from anon, authenticated';
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant all on table service_heartbeats to service_role';
  end if;
  -- n8n_engine não toca em nada de public
  execute 'revoke all on all tables in schema public from n8n_engine';
  execute 'revoke all on all sequences in schema public from n8n_engine';
end $$;

-- Registro no histórico (para aparecer junto das migrações 0001–0005)
insert into supabase_migrations.schema_migrations(version, name, created_by)
values ('20261002060000', '0006_api_interface', 'ntjautomacao (sql editor)')
on conflict (version) do nothing;
commit;
