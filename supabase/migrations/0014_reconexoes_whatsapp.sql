-- INFORUAN — 0014: reconexões curtas do WhatsApp sem alerta (observado de 06 a 14/10: ~5/dia, "connecting" → "open" em segundos).
-- • A pausa continua IMEDIATA em qualquer estado diferente de "open" (nada é enviado durante a queda)
--   e a liberação continua automática quando volta a "open".
-- • O alerta "WhatsApp desconectado" só sai se a queda durar mais de 3 min (um por queda); o "reconectado"
--   só sai se houve o alerta de queda. Checado pelo IR-07 (a cada 60 s) e pelo vigia (a cada 5 min).

create or replace function instance_outage_alerts(p_ws uuid, p_now timestamptz default now())
returns int language plpgsql as $$
declare i provider_instances; n int := 0;
begin
  for i in select * from provider_instances where workspace_id = p_ws and active and provider <> 'simulated'
             and state <> 'open' and paused and pause_reason = 'disconnected'
             and state_changed_at < p_now - interval '3 minutes' loop
    perform raise_alert(i.workspace_id, 'instance_disconnected', 'critical',
      '🔴 WhatsApp (' || i.instance_name || ') fora do ar há mais de 3 min (' || i.state || '). Envios pausados; nada será perdido.',
      'disc:' || i.instance_name || ':' || to_char(i.state_changed_at, 'YYYYMMDDHH24MISS'));
    n := n + 1;
  end loop;
  return n;
end $$;

create or replace function set_instance_state(p_instance text, p_state text, p_now timestamptz default now())
returns void language plpgsql as $$
declare i provider_instances; alerted boolean;
begin
  select * into i from provider_instances where instance_name = p_instance for update;
  if i.id is null then return; end if;
  update provider_instances set last_health_check_at = p_now where id = i.id;
  if i.state is distinct from p_state then
    update provider_instances set state = p_state, state_changed_at = p_now where id = i.id;
  end if;
  if p_state <> 'open' and not i.paused then
    update provider_instances set paused = true, pause_reason = 'disconnected' where id = i.id;   -- pausa imediata, sem alerta
  elsif p_state = 'open' and i.paused and i.pause_reason = 'disconnected' then
    update provider_instances set paused = false, pause_reason = null where id = i.id;
    alerted := exists (select 1 from alerts where workspace_id = i.workspace_id and kind = 'instance_disconnected'
                         and dedupe_key = 'disc:' || i.instance_name || ':' || to_char(i.state_changed_at, 'YYYYMMDDHH24MISS'));
    if alerted then
      perform raise_alert(i.workspace_id, 'instance_reconnected', 'info',
        '🟢 WhatsApp (' || p_instance || ') reconectado. Filas retomadas (mensagens vencidas expiram).',
        'reco:' || p_instance || ':' || to_char(p_now, 'YYYYMMDDHH24MI'));
    end if;
  elsif p_state <> 'open' then
    perform instance_outage_alerts(i.workspace_id, p_now);   -- queda que persiste: alerta quando passar de 3 min
  end if;
end $$;

create or replace function watchdog(p_ws_slug text, p_now timestamptz default now())
returns jsonb language plpgsql as $$
declare ws uuid := ws_id(p_ws_slug); tz text := setting_text(ws, 'timezone', 'America/Sao_Paulo'); lt time; n int;
begin
  lt := (p_now at time zone tz)::time;
  if lt between '08:00' and '23:00' and not exists (select 1 from webhook_inbox where workspace_id = ws and source = 'ggcheckout'
       and received_at > p_now - interval '2 hours') and exists (select 1 from webhook_inbox where workspace_id = ws and source = 'ggcheckout') then
    perform raise_alert(ws, 'no_gg_webhooks', 'warn', '⚠️ Nenhum evento da GGCheckout nas últimas 2h. Webhook caiu?',
                        'nogg:' || to_char(p_now, 'YYYYMMDDHH24'));
  end if;
  if exists (select 1 from provider_instances where workspace_id = ws and active and provider <> 'simulated'
            and (last_health_check_at is null or last_health_check_at < p_now - interval '5 minutes')) then
    perform raise_alert(ws, 'health_stale', 'warn', '⚠️ Health check do WhatsApp sem rodar há mais de 5 min (n8n parado?)',
                        'health:' || to_char(p_now, 'YYYYMMDDHH24'));
  end if;
  -- 0014: queda de conexão do WhatsApp que passou de 3 min (as curtas não alertam; ver set_instance_state)
  perform instance_outage_alerts(ws, p_now);
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

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname in ('instance_outage_alerts', 'set_instance_state', 'watchdog') loop
    execute format('revoke all on function %s from public', f.sig);
    execute format('alter function %s set search_path = public, pg_temp', f.sig);
    if exists (select 1 from pg_roles where rolname = 'anon') then
      execute format('revoke all on function %s from anon, authenticated', f.sig);
    end if;
    if exists (select 1 from pg_roles where rolname = 'service_role') then
      execute format('grant execute on function %s to service_role', f.sig);
    end if;
  end loop;
end $$;
