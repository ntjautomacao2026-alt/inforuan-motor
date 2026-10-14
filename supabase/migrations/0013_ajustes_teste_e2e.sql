-- INFORUAN — 0013: ajustes do 1º teste ponta a ponta (14/10/2026).
-- 1) Confirmações de entrega/leitura (messages.update) vinham com JID no formato LID (sem telefone) e eram descartadas
--    pelo modo só internos. Agora também são aceitas quando o id da mensagem é de um envio do motor a um contato interno.
-- 2) O webhook real da GGCheckout não traz checkoutId. Para os passos da régua que precisam do link de checkout,
--    o motor usa o checkout público de venda do mesmo produto (nunca o de teste).

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
    -- 0013: status (✓✓) e ecos podem vir com JID no formato LID (sem telefone). Reconhece pelo id da mensagem
    -- que o próprio motor enviou a um contato interno.
    if (ph is null or not coalesce(setting(ws, 'internal_test_phones') ? ph, false))
       and not (ev in ('messages.update', 'send.message') and exists (
             select 1 from outbound_messages om
              where om.provider_message_id = coalesce(d ->> 'keyId', d #>> '{key,id}') and om.is_internal_test)) then
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

create or replace function dispatch_due_actions(p_ws_slug text, p_limit int default 100, p_now timestamptz default now())
returns jsonb language plpgsql as $$
declare ws uuid := ws_id(p_ws_slug); a record; o orders; c contacts; st sequence_steps; e enrollments;
        ck catalog_checkouts; p catalog_products; vars jsonb; oid uuid; n_enq int := 0; n_skip int := 0; reason text;
begin
  for a in select sa.* from scheduled_actions sa join enrollments en on en.id = sa.enrollment_id
            where en.workspace_id = ws and sa.status = 'pending' and sa.due_at <= p_now
            order by sa.due_at limit p_limit for update of sa skip locked loop
    select * into e from enrollments where id = a.enrollment_id;
    select * into o from orders where id = a.order_id;
    select * into c from contacts where id = a.contact_id;
    select * into st from sequence_steps where id = a.step_id;
    select * into ck from catalog_checkouts where workspace_id = ws and external_checkout_id = o.external_checkout_id;
    -- 0013: o webhook real da GGCheckout não traz checkoutId → usa o checkout público de venda do mesmo produto
    if ck.external_checkout_id is null then
      select * into ck from catalog_checkouts where workspace_id = ws and external_product_id = o.external_product_id
         and not is_internal_test and public_url is not null order by external_checkout_id limit 1;
    end if;
    select * into p from catalog_products where workspace_id = ws and external_product_id = o.external_product_id;
    reason := case
      when e.status <> 'active' then 'enrollment_' || e.status
      when o.status in ('paid','refunded','chargeback') then 'order_' || o.status
      when exists (select 1 from orders x where x.contact_id = c.id and x.status = 'paid' and x.paid_at >= o.source_created_at) then 'contact_paid'
      when c.opted_out_at is not null then 'opted_out'
      when contact_in_human_mode(c.id, p_now) then 'human_handoff'
      when st.requires_checkout_url and ck.public_url is null then 'missing_checkout_url'
      else null end;
    if reason is not null then
      update scheduled_actions set status = case when reason like 'enrollment_%' or reason like 'order_%' or reason = 'contact_paid' then 'cancelled' else 'skipped' end,
             skip_reason = reason, processed_at = p_now where id = a.id;
      if reason = 'missing_checkout_url' then
        perform raise_alert(ws, 'missing_checkout_url', 'warn', 'Régua sem link de checkout cadastrado para ' ||
          coalesce(o.offer_title, o.external_checkout_id, '?') || ' — passos com link estão sendo pulados.',
          'missing_ck:' || coalesce(o.external_checkout_id, '?'));
      end if;
      n_skip := n_skip + 1;
      continue;
    end if;
    vars := jsonb_strip_nulls(jsonb_build_object(
      'nome', coalesce(first_name(c.name), 'tudo bem'),
      'produto', coalesce(p.title, o.offer_title, 'seu pedido'),
      'valor', to_char(coalesce(o.amount_cents, 0) / 100.0, 'FM999G990D00'),
      'pix_code', o.pix_code,
      'checkout_url', ck.public_url));
    begin
      oid := enqueue_message(ws, c.id, 'recovery', st.template_key, vars,
               'recovery:' || o.id || ':step:' || st.position, jsonb_build_object('order_unpaid', o.id, 'order_external_id', o.external_id),
               'enrollment', e.id::text, 5, p_now);
      update scheduled_actions set status = case when oid is null then 'skipped' else 'enqueued' end,
             skip_reason = case when oid is null then 'enqueue_refused' end, outbound_id = oid, processed_at = p_now where id = a.id;
      n_enq := n_enq + 1;
    exception when others then
      update scheduled_actions set status = 'skipped', skip_reason = left('error: ' || sqlerrm, 200), processed_at = p_now where id = a.id;
      n_skip := n_skip + 1;
    end;
    if not exists (select 1 from scheduled_actions where enrollment_id = e.id and status = 'pending') then
      update enrollments set status = 'completed', ended_at = p_now where id = e.id and status = 'active';
    end if;
  end loop;
  return jsonb_build_object('enqueued', n_enq, 'skipped', n_skip);
end $$;

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig, n.nspname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where (n.nspname = 'api' and p.proname = 'ingest_evolution_event')
               or (n.nspname = 'public' and p.proname = 'dispatch_due_actions') loop
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
