-- INFORUAN — 0011: WhatsApp via Evolution própria (doc 20, Fase 3). Porta de entrada dos eventos da Evolution.
-- • A Evolution manda os eventos ao n8n pela rede interna (webhook global); o n8n chama SÓ api.ingest_evolution_event.
-- • Confere a instância, remove o token, aceita só eventos úteis e deduplica; processa na hora (o pg_cron cobre falhas).
-- • Modo só internos (engine_mode <> 'live'): mensagens E status de quem não é interno são DESCARTADOS sem gravar
--   telefone nem texto (fica só uma contagem com o tipo do evento). Conexão sempre passa.
-- • Instância 'inforuan-01' nasce INATIVA e PAUSADA, com limites de aquecimento. Ativar é passo explícito do operador.

insert into settings(workspace_id, key, value)
select id, 'evolution_instance', '"inforuan-01"' from workspaces where slug = 'inforuan'
on conflict (workspace_id, key) do nothing;

insert into provider_instances(workspace_id, provider, instance_name, phone_e164, state, paused, pause_reason,
                               rate_per_minute, min_gap_seconds, daily_cap, active)
select id, 'evolution', 'inforuan-01', null, 'close', true, 'not_activated', 2, 30, 40, false
from workspaces where slug = 'inforuan'
on conflict (instance_name) do nothing;

-- Telefone a partir de um JID (inclui o formato de status: data.remoteJid). NULL para grupos, LID sem telefone etc.
create or replace function evo_jid_phone(p_jid text) returns text language sql immutable as $$
  select case when p_jid like '%@s.whatsapp.net' then norm_phone_br(split_part(p_jid, '@', 1)) end
$$;

create or replace function api.ingest_evolution_event(p_payload jsonb)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare ws uuid := ws_id('inforuan'); inst text := p_payload ->> 'instance';
        ev text := lower(replace(coalesce(p_payload ->> 'event', ''), '_', '.'));
        payload jsonb := p_payload - 'apikey'; d jsonb; ph text; id text; st text; k text; res jsonb;
begin
  if inst is distinct from setting_text(ws, 'evolution_instance', 'inforuan-01') then
    return jsonb_build_object('accepted', false, 'reason', 'wrong_instance');
  end if;
  if ev not in ('messages.upsert', 'send.message', 'messages.update', 'connection.update') then
    return jsonb_build_object('accepted', false, 'reason', 'ignored_event');
  end if;
  d := case when jsonb_typeof(payload -> 'data') = 'array' then payload -> 'data' -> 0 else payload -> 'data' end;

  if ev <> 'connection.update' and not engine_live(ws) then
    ph := coalesce(evo_phone(d), evo_jid_phone(d ->> 'remoteJid'));
    if ph is null or not coalesce(setting(ws, 'internal_test_phones') ? ph, false) then
      insert into events(workspace_id, type, occurred_at, source, payload)
      values (ws, 'evo.ignored_internal_only', now(), 'evolution', jsonb_build_object('event', ev));
      return jsonb_build_object('accepted', false, 'reason', 'internal_only');
    end if;
  end if;

  id := coalesce(d #>> '{key,id}', d ->> 'keyId', '');
  st := coalesce(d ->> 'status', d #>> '{update,status}', d ->> 'state', '');
  k  := ev || '|' || id || '|' || st || '|' || case when id = '' then coalesce(payload ->> 'date_time', now()::text) else '' end;
  res := ingest_webhook('inforuan', 'evolution', k, ev, '{}'::jsonb, payload);
  perform process_pending_inbox(20);
  return jsonb_build_object('accepted', true, 'duplicate', (res ->> 'duplicate')::boolean);
end $$;

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig, n.nspname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where (n.nspname = 'api' and p.proname = 'ingest_evolution_event')
               or (n.nspname = 'public' and p.proname = 'evo_jid_phone') loop
    execute format('revoke all on function %s from public', f.sig);
    if f.nspname = 'public' then execute format('alter function %s set search_path = public, pg_temp', f.sig); end if;
    if exists (select 1 from pg_roles where rolname = 'anon') then
      execute format('revoke all on function %s from anon, authenticated', f.sig);
    end if;
    if f.nspname = 'api' then execute format('grant execute on function %s to n8n_engine', f.sig); end if;
    if exists (select 1 from pg_roles where rolname = 'service_role') then
      execute format('grant execute on function %s to service_role', f.sig);
    end if;
  end loop;
end $$;
