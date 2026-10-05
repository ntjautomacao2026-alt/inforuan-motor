-- INFORUAN — 0007: modo "só internos", envio simulado e funções de agendamento.
-- • engine_mode: qualquer valor diferente de 'live' = SÓ INTERNOS. A régua só matricula contatos internos
--   (settings.internal_test_phones) e nenhuma mensagem é enfileirada para quem não é interno.
--   Defesa em profundidade: o claim também cancela mensagens de não internos fora do modo 'live'.
-- • provedor 'simulated': instância que "envia" só para contatos internos, sem sair do banco. Nasce PAUSADA.
-- • engine_tick / engine_housekeeping: o que o IR-03 e o IR-07 faziam em SQL puro, para o pg_cron (0008).
-- Nada aqui envia mensagem, ativa a régua ou agenda tarefas.

-- ─── Modo do motor ───────────────────────────────────────────────────────────
insert into settings(workspace_id, key, value)
select id, 'engine_mode', '"internal_only"' from workspaces where slug = 'inforuan'
on conflict (workspace_id, key) do nothing;

create or replace function engine_live(p_ws uuid) returns boolean
language sql stable as $$ select setting_text(p_ws, 'engine_mode', 'internal_only') = 'live' $$;

-- Troca de modo: só operador (service_role / SQL Editor). 'live' exige autorização explícita.
create or replace function set_engine_mode(p_ws_slug text, p_mode text, p_by text, p_now timestamptz default now())
returns text language plpgsql as $$
declare ws uuid := ws_id(p_ws_slug);
begin
  if p_mode not in ('internal_only', 'live') then raise exception 'engine_mode_invalid: %', p_mode; end if;
  if p_by is null or length(trim(p_by)) = 0 then raise exception 'engine_mode_requires_operator'; end if;
  insert into settings(workspace_id, key, value, updated_at) values (ws, 'engine_mode', to_jsonb(p_mode), p_now)
  on conflict (workspace_id, key) do update set value = excluded.value, updated_at = excluded.updated_at;
  perform raise_alert(ws, 'engine_mode', case when p_mode = 'live' then 'critical' else 'info' end,
    case when p_mode = 'live' then '🔴 Motor em modo LIVE (clientes reais) por ' else '🟢 Motor em modo SÓ INTERNOS por ' end || p_by,
    'mode:' || p_mode || ':' || to_char(p_now, 'YYYYMMDDHH24MISS'));
  return p_mode;
end $$;

-- ─── Régua: fora do modo live, só contatos internos são matriculados ─────────
create or replace function on_order_pix_generated(p_ws uuid, p_order uuid, p_now timestamptz) returns void
language plpgsql as $$
declare o orders; c contacts; s sequences; e experiments; st sequence_steps; enr uuid; a text;
        tz text; ws_start time; ws_end time; due timestamptz; base timestamptz;
begin
  select * into o from orders where id = p_order;
  if o.contact_id is null or o.payment_method is distinct from 'pix' or o.status <> 'pending' then return; end if;
  select * into c from contacts where id = o.contact_id;
  if c.phone_e164 is null or c.opted_out_at is not null then return; end if;
  -- modo só internos: cliente real não é matriculado nem sorteado no holdout (não contamina o experimento)
  if not engine_live(p_ws) and not c.is_internal_test then return; end if;
  select * into s from sequences where workspace_id = p_ws and key = 'recovery_pix' and active;
  if s.id is null then return; end if;
  -- já pagou alguma coisa depois deste pedido? (ex.: outro Pix)
  if exists (select 1 from orders where contact_id = o.contact_id and status = 'paid' and paid_at >= o.source_created_at) then return; end if;

  select * into e from experiments where workspace_id = p_ws and key = s.experiment_key and status = 'running';
  a := case when e.id is null then 'treatment' else assign_arm(e.id, c.id, c.is_internal_test) end;
  base := coalesce(o.source_created_at, p_now);

  insert into enrollments(workspace_id, contact_id, sequence_id, order_id, arm, is_internal_test, eligible_at, started_at)
  values (p_ws, c.id, s.id, o.id, a, c.is_internal_test,
          base + make_interval(mins => coalesce(e.eligibility_offset_minutes, 6)), p_now)
  on conflict (sequence_id, order_id) do nothing
  returning id into enr;
  if enr is null or a = 'control' then return; end if;   -- controle: registrado, sem ações

  tz := setting_text(p_ws, 'timezone', 'America/Sao_Paulo');
  ws_start := (setting(p_ws, 'send_window') ->> 'start')::time;
  ws_end   := (setting(p_ws, 'send_window') ->> 'end')::time;

  for st in select * from sequence_steps where sequence_id = s.id and active order by position loop
    due := base + make_interval(mins => st.delay_minutes);
    if st.respect_send_window then due := next_allowed_at(due, tz, ws_start, ws_end); end if;
    insert into scheduled_actions(enrollment_id, step_id, contact_id, order_id, due_at)
    values (enr, st.id, c.id, o.id, due) on conflict do nothing;
  end loop;
end $$;

-- ─── Fila: fora do modo live, nada é enfileirado para quem não é interno ─────
create or replace function enqueue_message(
  p_ws uuid, p_contact uuid, p_purpose text, p_template_key text, p_vars jsonb, p_idem text,
  p_guard jsonb default '{}', p_source_type text default null, p_source_id text default null,
  p_priority int default 5, p_now timestamptz default now(), p_allow_opted_out boolean default false)
returns uuid language plpgsql as $$
declare c contacts; t message_templates; body text; oid uuid; v_arm text;
begin
  if p_purpose not in ('recovery','post_purchase','support','handoff_notice') then
    raise exception 'purpose_not_allowed: %', p_purpose;
  end if;
  select * into c from contacts where id = p_contact;
  if c.id is null or c.phone_e164 is null then raise exception 'contact_without_phone'; end if;
  if not engine_live(p_ws) and not c.is_internal_test then
    insert into events(workspace_id, type, occurred_at, contact_id, source, payload)
    values (p_ws, 'outbound.suppressed', p_now, c.id, 'engine',
            jsonb_build_object('reason', 'internal_only', 'purpose', p_purpose, 'template', p_template_key, 'idempotency_key', p_idem));
    return null;
  end if;
  if c.opted_out_at is not null and not p_allow_opted_out then return null; end if;
  if not has_transactional_link(p_contact, p_now) then raise exception 'no_transactional_link'; end if;

  select * into t from message_templates
   where workspace_id = p_ws and key = p_template_key and active order by version desc limit 1;
  if t.key is null then raise exception 'template_not_found: %', p_template_key; end if;
  if t.purpose <> p_purpose then raise exception 'template_purpose_mismatch: % vs %', t.purpose, p_purpose; end if;

  body := render_template(t.body_text, p_vars);
  select e.arm into v_arm from enrollments e where e.id::text = p_source_id;

  insert into outbound_messages(workspace_id, contact_id, to_phone_e164, purpose, template_key, template_version,
    variables, rendered_body, content_hash, idempotency_key, source_type, source_id, guard, priority,
    ttl_at, is_internal_test, experiment_arm, queued_at, next_attempt_at)
  values (p_ws, p_contact, c.phone_e164, p_purpose, t.key, t.version, coalesce(p_vars, '{}'), body,
    md5(c.phone_e164 || '|' || body), p_idem, p_source_type, p_source_id, coalesce(p_guard, '{}'), p_priority,
    p_now + make_interval(mins => t.ttl_minutes), c.is_internal_test, v_arm, p_now, p_now)
  on conflict (idempotency_key) do nothing
  returning id into oid;

  if oid is null then select id into oid from outbound_messages where idempotency_key = p_idem; end if;
  return oid;
end $$;

-- ─── Provedor simulado ───────────────────────────────────────────────────────
alter table provider_instances drop constraint if exists provider_instances_provider_check;
alter table provider_instances add constraint provider_instances_provider_check
  check (provider in ('evolution', 'meta_cloud', 'simulated'));

insert into provider_instances(workspace_id, provider, instance_name, phone_e164, state, paused, pause_reason,
                               rate_per_minute, min_gap_seconds, daily_cap)
select id, 'simulated', 'inforuan-sim', null, 'open', true, 'not_activated', 30, 0, 200
from workspaces where slug = 'inforuan'
on conflict (instance_name) do nothing;

-- ─── Claim: fora do live, cancela não internos; instância simulada só pega internos ─
create or replace function claim_outbound(p_instance text, p_limit int default 1, p_now timestamptz default now())
returns setof outbound_messages language plpgsql as $$
declare i provider_instances; allow int; n_min int; n_day int; m outbound_messages; reason text; tz text; live boolean;
begin
  select * into i from provider_instances where instance_name = p_instance and active for update;
  if i.id is null or i.paused or i.state <> 'open' then return; end if;
  if i.last_claimed_at is not null and i.last_claimed_at > p_now - make_interval(secs => i.min_gap_seconds) then return; end if;
  tz := setting_text(i.workspace_id, 'timezone', 'America/Sao_Paulo');
  live := engine_live(i.workspace_id);
  select count(*) into n_min from outbound_messages where provider_instance = p_instance and claimed_at > p_now - interval '60 seconds';
  select count(*) into n_day from outbound_messages where provider_instance = p_instance
     and claimed_at >= ((p_now at time zone tz)::date)::timestamp at time zone tz;
  allow := least(p_limit, i.rate_per_minute - n_min, i.daily_cap - n_day);
  if allow <= 0 then return; end if;

  for m in select * from outbound_messages where workspace_id = i.workspace_id and status = 'queued' and next_attempt_at <= p_now
             and (i.provider <> 'simulated' or is_internal_test)
           order by priority, queued_at limit 50 for update skip locked loop
    reason := case
      when m.ttl_at <= p_now then 'ttl'
      when not live and not m.is_internal_test then 'internal_only'
      when exists (select 1 from contacts where id = m.contact_id and opted_out_at is not null) and m.template_key <> 'opt_out_confirmacao' then 'opted_out'
      when m.guard ? 'order_unpaid' and exists (select 1 from orders o where o.id = (m.guard ->> 'order_unpaid')::uuid
             and (o.status in ('paid','refunded','chargeback')
                  or exists (select 1 from orders x where x.contact_id = o.contact_id and x.status = 'paid' and x.paid_at >= o.source_created_at))) then 'paid'
      when m.purpose = 'recovery' and contact_in_human_mode(m.contact_id, p_now) then 'human_handoff'
      else null end;
    if reason = 'ttl' then
      update outbound_messages set status = 'expired', status_reason = 'ttl' where id = m.id;
      continue;
    elsif reason is not null then
      update outbound_messages set status = 'cancelled', status_reason = reason where id = m.id;
      continue;
    end if;
    update outbound_messages set status = 'sending', attempts = attempts + 1, claimed_at = p_now,
           provider = i.provider, provider_instance = i.instance_name
     where id = m.id returning * into m;
    update provider_instances set last_claimed_at = p_now where id = i.id;
    return next m;
    allow := allow - 1;
    exit when allow <= 0;
  end loop;
end $$;

-- "Envia" pela instância simulada: reserva com todas as regras do claim e marca como enviada (id 'sim:…').
create or replace function simulate_outbound(p_instance text default 'inforuan-sim', p_limit int default 10,
                                             p_now timestamptz default now())
returns jsonb language plpgsql as $$
declare i provider_instances; m outbound_messages; n int := 0;
begin
  select * into i from provider_instances where instance_name = p_instance;
  if i.id is null or i.provider <> 'simulated' then raise exception 'not_a_simulated_instance: %', p_instance; end if;
  for m in select * from claim_outbound(p_instance, p_limit, p_now) loop
    perform mark_outbound_result(m.id, true, 'sim:' || m.id, null, false, false, p_now);
    n := n + 1;
  end loop;
  return jsonb_build_object('simulated', n);
end $$;

-- ─── Vigia: instância simulada não tem health check ──────────────────────────
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

-- ─── Tarefas de banco (chamadas pelo pg_cron na 0008) ────────────────────────
-- Tick: inbox → régua → destravar envios → envio simulado (só se a instância simulada estiver liberada).
create or replace function engine_tick(p_ws_slug text, p_now timestamptz default now())
returns jsonb language plpgsql as $$
declare ws uuid := ws_id(p_ws_slug); r_inbox jsonb; r_disp jsonb; r_reap jsonb; r_sim jsonb := null; si text;
begin
  r_inbox := process_pending_inbox(100, p_now);
  r_disp  := dispatch_due_actions(p_ws_slug, 100, p_now);
  r_reap  := reap_outbound(p_now);
  select instance_name into si from provider_instances
   where workspace_id = ws and provider = 'simulated' and active and not paused order by instance_name limit 1;
  if si is not null then r_sim := simulate_outbound(si, 10, p_now); end if;
  perform record_heartbeat('db_tick', '{}'::jsonb, p_now);
  return jsonb_strip_nulls(jsonb_build_object('inbox', r_inbox, 'dispatch', r_disp, 'reap', r_reap, 'sim', r_sim));
end $$;

-- Manutenção leve: handoffs (expirar / fila das 9h) + vigia.
create or replace function engine_housekeeping(p_ws_slug text, p_now timestamptz default now())
returns jsonb language plpgsql as $$
begin
  return jsonb_build_object('handoffs', handoff_housekeeping(p_ws_slug, p_now), 'watchdog', watchdog(p_ws_slug, p_now));
end $$;

-- ─── Permissões: nada para anon/authenticated/n8n_engine; search_path fixo ───
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname in ('engine_live','set_engine_mode','on_order_pix_generated','enqueue_message',
              'claim_outbound','simulate_outbound','watchdog','engine_tick','engine_housekeeping') loop
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
