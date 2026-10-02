-- INFORUAN — 0002: funções do motor.
-- Regras críticas ficam AQUI (transacionais), não no n8n.
-- Toda função sensível a tempo recebe p_now (default now()) para ser testável.

-- ═══ Utilitários ═════════════════════════════════════════════════════════════
create or replace function ws_id(p_slug text) returns uuid
language sql stable as $$ select id from workspaces where slug = p_slug $$;

create or replace function setting(p_ws uuid, p_key text) returns jsonb
language sql stable as $$ select value from settings where workspace_id = p_ws and key = p_key $$;

create or replace function setting_text(p_ws uuid, p_key text, p_default text) returns text
language sql stable as $$ select coalesce((select value #>> '{}' from settings where workspace_id = p_ws and key = p_key), p_default) $$;

-- Telefone BR → E.164 (+55DDDNUMERO). NULL se inválido.
create or replace function norm_phone_br(p_raw text) returns text
language plpgsql immutable as $$
declare d text;
begin
  if p_raw is null then return null; end if;
  d := regexp_replace(p_raw, '\D', '', 'g');
  if length(d) in (10, 11) then d := '55' || d; end if;
  if d !~ '^55\d{10,11}$' then return null; end if;
  return '+' || d;
end $$;

create or replace function norm_email(p_raw text) returns text
language sql immutable as $$
  select case when p_raw is null or p_raw !~ '@' or p_raw ~* 'noreply\.ggcheckout' then null else lower(trim(p_raw)) end
$$;

create or replace function first_name(p_name text) returns text
language sql immutable as $$
  select nullif(initcap(split_part(trim(coalesce(p_name, '')), ' ', 1)), '')
$$;

-- Próximo instante permitido dentro da janela local [start, end).
create or replace function next_allowed_at(p_ts timestamptz, p_tz text, p_start time, p_end time)
returns timestamptz language plpgsql immutable as $$
declare l timestamp := p_ts at time zone p_tz; t time := l::time;
begin
  if t >= p_start and t < p_end then return p_ts; end if;
  if t < p_start then return (l::date + p_start) at time zone p_tz; end if;
  return ((l::date + 1) + p_start) at time zone p_tz;
end $$;

create or replace function in_window(p_ts timestamptz, p_tz text, p_start time, p_end time)
returns boolean language sql immutable as $$
  select (p_ts at time zone p_tz)::time >= p_start and (p_ts at time zone p_tz)::time < p_end
$$;

create or replace function render_template(p_body text, p_vars jsonb) returns text
language plpgsql immutable as $$
declare r record; out text := p_body;
begin
  for r in select key, value from jsonb_each_text(coalesce(p_vars, '{}'::jsonb)) loop
    out := replace(out, '{{' || r.key || '}}', coalesce(r.value, ''));
  end loop;
  if out ~ '\{\{[a-z_0-9]+\}\}' then
    raise exception 'template_missing_var: %', substring(out from '\{\{[a-z_0-9]+\}\}');
  end if;
  return out;
end $$;

create or replace function raise_alert(p_ws uuid, p_kind text, p_severity text, p_text text, p_dedupe text default null)
returns void language plpgsql as $$
begin
  insert into alerts(workspace_id, kind, severity, text, dedupe_key)
  values (p_ws, p_kind, p_severity, p_text, p_dedupe)
  on conflict do nothing;
end $$;

-- ═══ Holdout ═════════════════════════════════════════════════════════════════
-- Aleatório (hash com salt), estável (gravado na 1ª vez), registrado antes do 1º envio.
create or replace function assign_arm(p_experiment_id uuid, p_contact_id uuid, p_force_treatment boolean default false)
returns text language plpgsql as $$
declare e experiments; b int; a text;
begin
  select * into e from experiments where id = p_experiment_id;
  select arm into a from experiment_assignments where experiment_id = p_experiment_id and contact_id = p_contact_id;
  if a is not null then return a; end if;
  b := (('x' || substr(md5(e.salt || ':' || p_contact_id::text), 1, 8))::bit(32)::bigint % 100)::int;
  if b < 0 then b := b + 100; end if;
  a := case when p_force_treatment then 'treatment' when b < e.holdout_pct then 'control' else 'treatment' end;
  insert into experiment_assignments(experiment_id, contact_id, arm, bucket, forced)
  values (p_experiment_id, p_contact_id, a, b, p_force_treatment)
  on conflict (experiment_id, contact_id) do nothing;
  select arm into a from experiment_assignments where experiment_id = p_experiment_id and contact_id = p_contact_id;
  return a;
end $$;

-- ═══ Contatos ════════════════════════════════════════════════════════════════
create or replace function upsert_contact(p_ws uuid, p_phone_raw text, p_email_raw text, p_name text, p_now timestamptz default now())
returns uuid language plpgsql as $$
declare ph text := norm_phone_br(p_phone_raw); em text := norm_email(p_email_raw); cid uuid;
        internal boolean := false;
begin
  if ph is null and em is null then return null; end if;
  if ph is not null then
    internal := coalesce(setting(p_ws, 'internal_test_phones') ? ph, false);
    select id into cid from contacts where workspace_id = p_ws and phone_e164 = ph;
  end if;
  if cid is null and em is not null then
    select id into cid from contacts where workspace_id = p_ws and email_norm = em
      and (phone_e164 is null or phone_e164 = ph) order by created_at limit 1;
  end if;
  if cid is null then
    insert into contacts(workspace_id, phone_e164, email_norm, name, first_seen_at, is_internal_test)
    values (p_ws, ph, em, nullif(trim(p_name), ''), p_now, internal)
    on conflict (workspace_id, phone_e164) where phone_e164 is not null
      do update set updated_at = excluded.updated_at
    returning id into cid;
  else
    update contacts set
      phone_e164 = coalesce(phone_e164, ph),
      email_norm = coalesce(email_norm, em),
      name = coalesce(nullif(trim(p_name), ''), name),
      is_internal_test = is_internal_test or internal,
      updated_at = p_now
    where id = cid;
  end if;
  return cid;
end $$;

create or replace function contact_in_human_mode(p_contact uuid, p_now timestamptz default now())
returns boolean language sql stable as $$
  select exists (select 1 from handoffs where contact_id = p_contact and status in ('open','queued') and expires_at > p_now)
$$;

-- Tem vínculo transacional? (pedido nos últimos 30 dias ou mensagem recebida nos últimos 7)
create or replace function has_transactional_link(p_contact uuid, p_now timestamptz default now())
returns boolean language sql stable as $$
  select exists (select 1 from orders where contact_id = p_contact and created_at > p_now - interval '30 days')
      or exists (select 1 from messages where contact_id = p_contact and direction = 'in' and occurred_at > p_now - interval '7 days')
$$;

-- ═══ Camada de envio: enfileirar ═════════════════════════════════════════════
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

-- Cancela mensagens de recuperação ainda não enviadas de um contato.
create or replace function cancel_recovery_for_contact(p_contact uuid, p_reason text, p_now timestamptz default now())
returns void language plpgsql as $$
begin
  update scheduled_actions sa set status = 'cancelled', skip_reason = p_reason, processed_at = p_now
   from enrollments e
   where sa.enrollment_id = e.id and e.contact_id = p_contact and sa.status = 'pending';
  update enrollments set status = 'exited', exit_reason = p_reason, ended_at = p_now
   where contact_id = p_contact and status = 'active';
  update outbound_messages set status = 'cancelled', status_reason = p_reason
   where contact_id = p_contact and purpose = 'recovery' and status in ('queued','uncertain');
end $$;

-- ═══ Pedidos: aplicar status (webhook, reconciliação, checagem pré-envio) ═════
create or replace function status_rank(p text) returns int language sql immutable as $$
  select case p when 'pending' then 1 when 'failed' then 2 when 'expired' then 2 when 'cancelled' then 2
                when 'paid' then 5 when 'refunded' then 8 when 'chargeback' then 9 else 0 end
$$;

create or replace function on_order_paid(p_ws uuid, p_order uuid, p_now timestamptz) returns void
language plpgsql as $$
declare o orders; p catalog_products; c contacts;
begin
  select * into o from orders where id = p_order;
  if o.contact_id is null then return; end if;
  perform cancel_recovery_for_contact(o.contact_id, 'paid', p_now);
  select * into c from contacts where id = o.contact_id;
  if c.phone_e164 is null then return; end if;
  select * into p from catalog_products where workspace_id = p_ws and external_product_id = o.external_product_id;
  if p.access_url is null then
    perform raise_alert(p_ws, 'missing_access_url', 'warn',
      'Pós-venda NÃO enviado: produto sem link de acesso cadastrado (' || coalesce(o.offer_title, o.external_product_id) || ')',
      'missing_access_url:' || coalesce(o.external_product_id, '?'));
    return;
  end if;
  perform enqueue_message(p_ws, o.contact_id, 'post_purchase', 'pos_compra_acesso',
    jsonb_build_object('nome', coalesce(first_name(c.name), 'tudo bem'), 'produto', coalesce(p.title, o.offer_title),
                       'link_acesso', p.access_url),
    'post_purchase:' || o.id, '{}'::jsonb, 'order', o.id::text, 3, p_now);
end $$;

create or replace function on_order_pix_generated(p_ws uuid, p_order uuid, p_now timestamptz) returns void
language plpgsql as $$
declare o orders; c contacts; s sequences; e experiments; st sequence_steps; enr uuid; a text;
        tz text; ws_start time; ws_end time; due timestamptz; base timestamptz;
begin
  select * into o from orders where id = p_order;
  if o.contact_id is null or o.payment_method is distinct from 'pix' or o.status <> 'pending' then return; end if;
  select * into c from contacts where id = o.contact_id;
  if c.phone_e164 is null or c.opted_out_at is not null then return; end if;
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

-- Aplica um status de pedido de forma monotônica e dispara as regras de sistema.
create or replace function apply_order_status(
  p_ws uuid, p_external_id text, p_status text, p_occurred_at timestamptz, p_source text,
  p_contact uuid default null, p_fields jsonb default '{}', p_inbox bigint default null, p_now timestamptz default now())
returns uuid language plpgsql as $$
declare o orders; oid uuid; old_status text; internal boolean; is_new boolean := false;
begin
  select * into o from orders where workspace_id = p_ws and source = 'ggcheckout' and external_id = p_external_id for update;
  internal := coalesce((select is_internal_test from contacts where id = p_contact), false)
           or coalesce((select is_internal_test from catalog_checkouts
                         where workspace_id = p_ws and external_checkout_id = p_fields ->> 'checkout_id'), false);
  if o.id is null then
    is_new := true;
    insert into orders(workspace_id, external_id, contact_id, external_checkout_id, external_product_id, offer_title,
      status, payment_method, amount_cents, pix_code, pix_expires_at, source_created_at, paid_at, utm, is_internal_test, raw_last)
    values (p_ws, p_external_id, p_contact, p_fields ->> 'checkout_id', p_fields ->> 'product_id', p_fields ->> 'offer_title',
      p_status, p_fields ->> 'payment_method', (p_fields ->> 'amount_cents')::int, p_fields ->> 'pix_code',
      (p_fields ->> 'pix_expires_at')::timestamptz, coalesce((p_fields ->> 'created_at')::timestamptz, p_occurred_at),
      case when p_status = 'paid' then p_occurred_at end, coalesce(p_fields -> 'utm', '{}'), internal, p_fields -> 'raw')
    returning * into o;
    old_status := null;
  else
    old_status := o.status;
    update orders set
      contact_id           = coalesce(contact_id, p_contact),
      external_checkout_id = coalesce(external_checkout_id, p_fields ->> 'checkout_id'),
      external_product_id  = coalesce(external_product_id, p_fields ->> 'product_id'),
      offer_title          = coalesce(offer_title, p_fields ->> 'offer_title'),
      payment_method       = coalesce(payment_method, p_fields ->> 'payment_method'),
      amount_cents         = coalesce((p_fields ->> 'amount_cents')::int, amount_cents),
      pix_code             = coalesce(pix_code, p_fields ->> 'pix_code'),
      is_internal_test     = is_internal_test or internal,
      raw_last             = coalesce(p_fields -> 'raw', raw_last),
      status     = case when status_rank(p_status) >= status_rank(status) then p_status else status end,
      paid_at    = case when p_status = 'paid' and paid_at is null then p_occurred_at else paid_at end,
      refunded_at= case when p_status in ('refunded','chargeback') and refunded_at is null then p_occurred_at else refunded_at end,
      updated_at = p_now
    where id = o.id
    returning * into o;
  end if;

  insert into events(workspace_id, type, occurred_at, contact_id, order_id, source, inbox_id, payload)
  values (p_ws, 'order.' || p_status, p_occurred_at, o.contact_id, o.id, p_source, p_inbox,
          jsonb_build_object('previous_status', old_status, 'applied_status', o.status));

  -- Regras de sistema (só na TRANSIÇÃO efetiva)
  if o.status = 'paid' and old_status is distinct from 'paid' then
    perform on_order_paid(p_ws, o.id, p_now);
  elsif o.status in ('refunded','chargeback') and old_status is distinct from o.status then
    if o.contact_id is not null then
      update contacts set commercial_blocked_at = coalesce(commercial_blocked_at, p_now) where id = o.contact_id;
      perform cancel_recovery_for_contact(o.contact_id, o.status, p_now);
    end if;
    perform raise_alert(p_ws, 'order_' || o.status, 'warn',
      'Pedido ' || o.status || ': ' || coalesce(o.offer_title, '') || ' (' || o.external_id || ')', 'order_' || o.status || ':' || o.id);
  elsif o.status = 'pending' and is_new then
    perform on_order_pix_generated(p_ws, o.id, p_now);
  end if;
  return o.id;
end $$;

-- ═══ GGCheckout: normalização do payload ═════════════════════════════════════
create or replace function process_gg_payload(p_ws uuid, p_inbox bigint, p_payload jsonb, p_now timestamptz default now())
returns jsonb language plpgsql as $$
declare ev text := lower(coalesce(p_payload ->> 'event', '')); st text; pay jsonb := p_payload -> 'payment';
        cust jsonb := p_payload -> 'customer'; cid uuid; method text; amt numeric; ext text; oid uuid;
        occurred timestamptz; prod jsonb; item jsonb;
begin
  ext := coalesce(pay ->> 'id', p_payload ->> 'id');
  if ext is null then raise exception 'gg_payload_without_payment_id'; end if;

  st := case
    when ev in ('pix.generated','card.generated','card.pending','payment.created') then 'pending'
    when ev in ('pix.paid','card.paid','payment.paid') then 'paid'
    when ev in ('pix.expired','card.expired','payment.expired') then 'expired'
    when ev in ('pix.failed','card.failed') then 'failed'
    when ev in ('pix.refunded','card.refunded','payment.refunded') then 'refunded'
    when ev in ('payment.chargeback') then 'chargeback'
    else null end;
  if lower(coalesce(pay ->> 'status', '')) in ('charged_back','chargeback') then st := 'chargeback'; end if;
  if st is null then
    insert into events(workspace_id, type, occurred_at, source, inbox_id, payload)
    values (p_ws, 'gg.unknown_event', p_now, 'ggcheckout', p_inbox, jsonb_build_object('event', ev));
    return jsonb_build_object('ignored', ev);
  end if;

  method := case
    when coalesce(pay ->> 'paymentMethod', '') ilike '%pix%' or ev like 'pix.%' then 'pix'
    when coalesce(pay ->> 'paymentMethod', '') ilike '%card%' or ev like 'card.%' then 'credit_card'
    else pay ->> 'paymentMethod' end;
  amt := nullif(pay ->> 'amount', '')::numeric;            -- reais (doc) → centavos
  occurred := coalesce((p_payload ->> 'createdAt')::timestamptz, p_now);
  prod := coalesce(p_payload -> 'product', '{}');

  cid := upsert_contact(p_ws, coalesce(cust ->> 'phone', p_payload ->> 'phone'),
                        coalesce(cust ->> 'email', p_payload ->> 'email'), coalesce(cust ->> 'name', p_payload ->> 'name'), p_now);

  oid := apply_order_status(p_ws, ext, st, occurred, 'ggcheckout', cid, jsonb_build_object(
    'checkout_id', coalesce(p_payload ->> 'checkoutId', pay ->> 'checkoutId', p_payload #>> '{metadata,checkoutId}'),
    'product_id', prod ->> 'id', 'offer_title', coalesce(prod ->> 'title', p_payload ->> 'titleOffer'),
    'payment_method', method, 'amount_cents', case when amt is null then null else round(amt * 100)::int end,
    'pix_code', pay ->> 'pixCode', 'created_at', occurred,
    'utm', jsonb_strip_nulls(jsonb_build_object('utm_source', p_payload ->> 'utm_source', 'utm_medium', p_payload ->> 'utm_medium',
             'utm_campaign', p_payload ->> 'utm_campaign', 'utm_content', p_payload ->> 'utm_content', 'utm_term', p_payload ->> 'utm_term')),
    'raw', p_payload - 'customer'), p_inbox, p_now);

  for item in select * from jsonb_array_elements(coalesce(p_payload -> 'products', '[]'::jsonb)) loop
    insert into order_items(order_id, external_product_id, title, role, amount_cents)
    values (oid, item ->> 'id', item ->> 'title',
            case item ->> 'type' when 'orderbump' then 'bump' when 'upsell' then 'upsell' when 'downsell' then 'downsell' else 'main' end,
            nullif(item ->> 'price', '')::int)
    on conflict do nothing;
  end loop;
  return jsonb_build_object('order_id', oid, 'status', st, 'contact_id', cid);
end $$;

-- ═══ Entrada bruta ═══════════════════════════════════════════════════════════
create or replace function ingest_webhook(p_ws_slug text, p_source text, p_dedupe_key text, p_event_type text,
                                          p_headers jsonb, p_payload jsonb)
returns jsonb language plpgsql as $$
declare iid bigint; h jsonb := coalesce(p_headers, '{}');
begin
  -- defesa extra: nunca persistir segredos
  h := h - 'authorization' - 'Authorization' - 'x-secret' - 'X-Secret' - 'apikey' - 'cookie' - 'x-api-key';
  insert into webhook_inbox(workspace_id, source, dedupe_key, event_type, headers, payload)
  values (ws_id(p_ws_slug), p_source, p_dedupe_key, p_event_type, h, p_payload - 'apikey')
  on conflict (source, dedupe_key) do nothing
  returning id into iid;
  return jsonb_build_object('inbox_id', iid, 'duplicate', iid is null);
end $$;

-- ═══ Evolution: normalização ═════════════════════════════════════════════════
create or replace function evo_text(p_msg jsonb) returns text language sql immutable as $$
  select coalesce(p_msg ->> 'conversation', p_msg #>> '{extendedTextMessage,text}', p_msg #>> '{imageMessage,caption}',
                  p_msg #>> '{videoMessage,caption}', p_msg #>> '{documentMessage,caption}',
                  p_msg #>> '{buttonsResponseMessage,selectedDisplayText}', p_msg #>> '{listResponseMessage,title}')
$$;

create or replace function evo_phone(p_data jsonb) returns text language plpgsql immutable as $$
declare j text := p_data #>> '{key,remoteJid}'; alt text := coalesce(p_data #>> '{key,senderPn}', p_data #>> '{key,remoteJidAlt}');
begin
  if j like '%@s.whatsapp.net' then return norm_phone_br(split_part(j, '@', 1)); end if;
  if alt like '%@s.whatsapp.net' then return norm_phone_br(split_part(alt, '@', 1)); end if;
  return null;   -- grupos, status, newsletter, LID sem telefone
end $$;

create or replace function is_opt_out_text(p_text text) returns boolean language sql immutable as $$
  select translate(lower(trim(coalesce(p_text, ''))), 'áàâãéêíóôõúç', 'aaaaeeiooouc')
         = any (array['parar','pare','sair','stop','cancelar','descadastrar','nao quero receber','nao quero mais receber',
                      'para de mandar mensagem','nao me mande mais mensagem'])
$$;

create or replace function set_instance_state(p_instance text, p_state text, p_now timestamptz default now())
returns void language plpgsql as $$
declare i provider_instances;
begin
  select * into i from provider_instances where instance_name = p_instance for update;
  if i.id is null then return; end if;
  update provider_instances set last_health_check_at = p_now where id = i.id;
  if i.state is distinct from p_state then
    update provider_instances set state = p_state, state_changed_at = p_now where id = i.id;
  end if;
  if p_state <> 'open' and not i.paused then
    update provider_instances set paused = true, pause_reason = 'disconnected' where id = i.id;
    perform raise_alert(i.workspace_id, 'instance_disconnected', 'critical',
      '🔴 WhatsApp (' || p_instance || ') DESCONECTADO (' || p_state || '). Filas pausadas; nada será perdido.',
      'disc:' || p_instance || ':' || to_char(p_now, 'YYYYMMDDHH24'));
  elsif p_state = 'open' and i.paused and i.pause_reason = 'disconnected' then
    update provider_instances set paused = false, pause_reason = null where id = i.id;
    perform raise_alert(i.workspace_id, 'instance_reconnected', 'info',
      '🟢 WhatsApp (' || p_instance || ') reconectado. Filas retomadas (mensagens vencidas expiram).',
      'reco:' || p_instance || ':' || to_char(p_now, 'YYYYMMDDHH24MI'));
  end if;
end $$;

create or replace function record_status(p_provider text, p_pmid text, p_status text, p_raw jsonb, p_now timestamptz default now())
returns void language plpgsql as $$
begin
  insert into message_status_events(provider, provider_message_id, status, at, raw) values (p_provider, p_pmid, p_status, p_now, p_raw);
  update outbound_messages set
    status = case
      when p_status = 'failed' and status in ('sending','sent','uncertain') then 'failed'
      when p_status = 'read' and status in ('sending','sent','delivered','uncertain') then 'read'
      when p_status = 'delivered' and status in ('sending','sent','uncertain') then 'delivered'
      when p_status = 'sent' and status in ('sending','uncertain') then 'sent'
      else status end,
    sent_at      = case when p_status in ('sent','delivered','read') then coalesce(sent_at, p_now) else sent_at end,
    delivered_at = case when p_status in ('delivered','read') then coalesce(delivered_at, p_now) else delivered_at end,
    read_at      = case when p_status = 'read' then coalesce(read_at, p_now) else read_at end,
    failed_at    = case when p_status = 'failed' then coalesce(failed_at, p_now) else failed_at end
  where provider_message_id = p_pmid;
end $$;

-- ═══ Handoff humano (estado explícito) ═══════════════════════════════════════
create or replace function start_handoff(p_ws uuid, p_contact uuid, p_reason text, p_origin text,
                                         p_summary text default null, p_now timestamptz default now())
returns handoffs language plpgsql as $$
declare h handoffs; hrs jsonb := setting(p_ws, 'handoff_hours'); tz text := setting_text(p_ws, 'timezone', 'America/Sao_Paulo');
        hstart time := (hrs ->> 'start')::time; hend time := (hrs ->> 'end')::time;
        dur interval := make_interval(hours => coalesce((setting(p_ws, 'human_mode_hours') #>> '{}')::int, 12));
        c contacts;
begin
  select * into h from handoffs where contact_id = p_contact and status in ('open','queued') and expires_at > p_now;
  if h.id is not null then
    update handoffs set expires_at = greatest(expires_at, p_now + dur) where id = h.id returning * into h;
    return h;
  end if;
  update handoffs set status = 'expired' where contact_id = p_contact and status in ('open','queued');

  if in_window(p_now, tz, hstart, hend) then
    insert into handoffs(workspace_id, contact_id, reason, origin, status, started_at, expires_at, summary)
    values (p_ws, p_contact, p_reason, p_origin, 'open', p_now, p_now + dur, p_summary) returning * into h;
  else
    insert into handoffs(workspace_id, contact_id, reason, origin, status, started_at, expires_at, summary)
    values (p_ws, p_contact, p_reason, p_origin, 'queued', p_now, next_allowed_at(p_now, tz, hstart, hend) + dur, p_summary)
    returning * into h;
  end if;

  perform cancel_recovery_for_contact(p_contact, 'human_handoff', p_now);
  update conversations set ai_pending_since = null where contact_id = p_contact;

  if h.status = 'open' and p_origin <> 'human_reply_detected' then
    select * into c from contacts where id = p_contact;
    perform raise_alert(p_ws, 'handoff_open', 'warn',
      '🙋 Atendimento humano: ' || coalesce(first_name(c.name), 'cliente') || ' — https://wa.me/' || ltrim(c.phone_e164, '+') ||
      E'\nMotivo: ' || p_reason || coalesce(E'\nResumo: ' || p_summary, ''), 'handoff:' || h.id);
    update handoffs set notified_at = p_now where id = h.id;
  end if;
  return h;
end $$;

create or replace function release_handoff(p_ws_slug text, p_phone text, p_by text, p_now timestamptz default now())
returns int language plpgsql as $$
declare n int;
begin
  update handoffs h set status = 'released', released_at = p_now, released_by = p_by
    from contacts c
   where h.contact_id = c.id and c.workspace_id = ws_id(p_ws_slug) and c.phone_e164 = norm_phone_br(p_phone)
     and h.status in ('open','queued');
  get diagnostics n = row_count;
  return n;
end $$;

-- Cron: expira handoffs vencidos; às 9h promove a fila e manda o resumo.
create or replace function handoff_housekeeping(p_ws_slug text, p_now timestamptz default now())
returns jsonb language plpgsql as $$
declare ws uuid := ws_id(p_ws_slug); hrs jsonb; tz text; n_exp int; n_prom int; lst text;
begin
  hrs := setting(ws, 'handoff_hours'); tz := setting_text(ws, 'timezone', 'America/Sao_Paulo');
  update handoffs set status = 'expired' where workspace_id = ws and status in ('open','queued') and expires_at <= p_now;
  get diagnostics n_exp = row_count;
  n_prom := 0;
  if in_window(p_now, tz, (hrs ->> 'start')::time, (hrs ->> 'end')::time) then
    select string_agg('• ' || coalesce(first_name(c.name), 'cliente') || ' — https://wa.me/' || ltrim(c.phone_e164, '+') || ' (' || h.reason || ')', E'\n')
      into lst from handoffs h join contacts c on c.id = h.contact_id where h.workspace_id = ws and h.status = 'queued';
    update handoffs set status = 'open', notified_at = p_now where workspace_id = ws and status = 'queued';
    get diagnostics n_prom = row_count;
    if n_prom > 0 then
      perform raise_alert(ws, 'handoff_queue_digest', 'warn', '☀️ Fila de atendimento (' || n_prom || E'):\n' || lst,
                          'digest:' || to_char(p_now at time zone tz, 'YYYYMMDDHH24MI'));
    end if;
  end if;
  return jsonb_build_object('expired', n_exp, 'promoted', n_prom);
end $$;

-- ═══ Evolution: processamento de eventos ═════════════════════════════════════
create or replace function process_evolution_payload(p_ws uuid, p_inbox bigint, p_payload jsonb, p_now timestamptz default now())
returns jsonb language plpgsql as $$
declare ev text := lower(replace(coalesce(p_payload ->> 'event', ''), '_', '.')); d jsonb := p_payload -> 'data';
        inst text := p_payload ->> 'instance'; ph text; pmid text; fromme boolean; txt text; mtype text;
        cid uuid; conv uuid; ob outbound_messages; occurred timestamptz; h handoffs; st text; r jsonb;
begin
  if ev = 'connection.update' then
    perform set_instance_state(inst, coalesce(d ->> 'state', 'close'), p_now);
    return jsonb_build_object('connection', d ->> 'state');
  end if;

  if ev = 'messages.update' then
    for r in select * from jsonb_array_elements(case when jsonb_typeof(d) = 'array' then d else jsonb_build_array(d) end) loop
      pmid := coalesce(r ->> 'keyId', r #>> '{key,id}');
      st := case upper(coalesce(r ->> 'status', r #>> '{update,status}', ''))
              when 'SERVER_ACK' then 'sent' when 'DELIVERY_ACK' then 'delivered' when 'READ' then 'read'
              when 'PLAYED' then 'read' when 'ERROR' then 'failed' when 'FAILED' then 'failed' else null end;
      if pmid is not null and st is not null then perform record_status('evolution', pmid, st, r, p_now); end if;
    end loop;
    return jsonb_build_object('status_update', true);
  end if;

  if ev not in ('messages.upsert', 'send.message') then
    return jsonb_build_object('ignored', ev);
  end if;

  ph := evo_phone(d);
  if ph is null then return jsonb_build_object('ignored', 'no_phone_or_group'); end if;
  pmid := d #>> '{key,id}';
  fromme := coalesce((d #>> '{key,fromMe}')::boolean, ev = 'send.message');
  txt := evo_text(d -> 'message');
  mtype := coalesce(d ->> 'messageType', 'unknown');
  occurred := coalesce(to_timestamp(nullif(d ->> 'messageTimestamp', '')::bigint), p_now);

  if fromme then
    select * into ob from outbound_messages where provider_message_id = pmid;
    if ob.id is null then   -- resultado incerto? casa pelo conteúdo
      select * into ob from outbound_messages
       where status in ('uncertain','sending') and to_phone_e164 = ph and content_hash = md5(ph || '|' || coalesce(txt, ''))
         and claimed_at > p_now - interval '15 minutes' order by claimed_at desc limit 1;
      if ob.id is null then   -- eco chegou antes do resultado do adapter e o texto não casou: não é humano
        select * into ob from outbound_messages
         where status in ('sending','uncertain') and to_phone_e164 = ph and provider_message_id is null
           and claimed_at > p_now - interval '2 minutes' order by claimed_at desc limit 1;
      end if;
      if ob.id is not null then
        update outbound_messages set provider_message_id = pmid, status = 'sent', sent_at = coalesce(sent_at, occurred) where id = ob.id;
      end if;
    elsif ob.status in ('sending','uncertain') then
      update outbound_messages set status = 'sent', sent_at = coalesce(sent_at, occurred) where id = ob.id;
    end if;
    cid := coalesce(ob.contact_id, (select id from contacts where workspace_id = p_ws and phone_e164 = ph));
    if cid is null then return jsonb_build_object('ignored', 'echo_unknown_contact'); end if;
    insert into conversations(workspace_id, contact_id) values (p_ws, cid) on conflict (contact_id) do nothing;
    select id into conv from conversations where contact_id = cid;
    insert into messages(workspace_id, contact_id, conversation_id, direction, provider, provider_instance, provider_message_id,
                         from_me, origin, type, text, outbound_id, occurred_at)
    values (p_ws, cid, conv, 'out', 'evolution', inst, pmid, true, case when ob.id is null then 'human_phone' else 'engine' end,
            mtype, txt, ob.id, occurred)
    on conflict (provider, provider_message_id) do nothing;
    update conversations set last_outbound_at = occurred where id = conv;
    if ob.id is null then   -- humano respondeu pelo celular → modo humano
      h := start_handoff(p_ws, cid, 'resposta humana detectada', 'human_reply_detected', null, p_now);
      return jsonb_build_object('route', 'human_reply', 'handoff', h.status);
    end if;
    return jsonb_build_object('route', 'echo');
  end if;

  -- Mensagem do cliente
  cid := upsert_contact(p_ws, ph, null, d ->> 'pushName', p_now);
  insert into conversations(workspace_id, contact_id) values (p_ws, cid) on conflict (contact_id) do nothing;
  select id into conv from conversations where contact_id = cid;
  insert into messages(workspace_id, contact_id, conversation_id, direction, provider, provider_instance, provider_message_id,
                       from_me, origin, type, text, occurred_at)
  values (p_ws, cid, conv, 'in', 'evolution', inst, pmid, false, 'customer', mtype, txt, occurred)
  on conflict (provider, provider_message_id) do nothing;
  if not found then return jsonb_build_object('route', 'duplicate'); end if;
  update conversations set last_inbound_at = occurred where id = conv;

  if is_opt_out_text(txt) then
    update contacts set opted_out_at = coalesce(opted_out_at, p_now), opted_out_reason = 'keyword' where id = cid;
    perform cancel_recovery_for_contact(cid, 'opted_out', p_now);
    update outbound_messages set status = 'cancelled', status_reason = 'opted_out'
     where contact_id = cid and status in ('queued','uncertain') and purpose <> 'handoff_notice';
    perform enqueue_message(p_ws, cid, 'support', 'opt_out_confirmacao', '{}'::jsonb, 'optout:' || pmid,
                            '{}'::jsonb, 'message', pmid, 1, p_now, true);
    return jsonb_build_object('route', 'opt_out');
  end if;

  -- Resposta do cliente pausa a régua
  perform cancel_recovery_for_contact(cid, 'customer_replied', p_now);

  if contact_in_human_mode(cid, p_now) then
    return jsonb_build_object('route', 'human');
  end if;

  if txt is null or mtype in ('audioMessage','imageMessage','documentMessage','videoMessage','stickerMessage') then
    h := start_handoff(p_ws, cid, 'mensagem não-texto (' || mtype || ')', 'non_text_message', null, p_now);
    perform enqueue_message(p_ws, cid, 'handoff_notice',
      case when h.status = 'open' then 'handoff_aberto' else 'handoff_fila' end,
      '{}'::jsonb, 'handoff_notice:' || h.id, '{}'::jsonb, 'handoff', h.id::text, 2, p_now);
    return jsonb_build_object('route', 'handoff', 'status', h.status);
  end if;

  update conversations set ai_pending_since = coalesce(ai_pending_since, p_now) where id = conv;
  return jsonb_build_object('route', 'ai');
end $$;

-- ═══ Processador da inbox (etapa separada da ingestão) ═══════════════════════
create or replace function process_pending_inbox(p_limit int default 50, p_now timestamptz default now())
returns jsonb language plpgsql as $$
declare r webhook_inbox; res jsonb; ok int := 0; fail int := 0;
begin
  for r in select * from webhook_inbox where processed_at is null and attempts < 5
           order by id limit p_limit for update skip locked loop
    begin
      if r.source = 'ggcheckout' then res := process_gg_payload(r.workspace_id, r.id, r.payload, p_now);
      elsif r.source = 'evolution' then res := process_evolution_payload(r.workspace_id, r.id, r.payload, p_now);
      else res := jsonb_build_object('ignored_source', r.source); end if;
      update webhook_inbox set processed_at = p_now, attempts = attempts + 1, error = null where id = r.id;
      ok := ok + 1;
    exception when others then
      update webhook_inbox set attempts = attempts + 1, error = left(sqlerrm, 500) where id = r.id;
      if r.attempts + 1 >= 5 then
        perform raise_alert(r.workspace_id, 'inbox_failed', 'critical',
          'Evento ' || r.source || '/' || coalesce(r.event_type, '?') || ' falhou 5x: ' || left(sqlerrm, 200), 'inbox:' || r.id);
      end if;
      fail := fail + 1;
    end;
  end loop;
  return jsonb_build_object('processed', ok, 'failed', fail);
end $$;

-- ═══ Régua: ações vencidas → fila de envio ═══════════════════════════════════
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

-- ═══ Camada de envio: reservar lote (limites + pausa + guard + TTL) ══════════
create or replace function claim_outbound(p_instance text, p_limit int default 1, p_now timestamptz default now())
returns setof outbound_messages language plpgsql as $$
declare i provider_instances; allow int; n_min int; n_day int; m outbound_messages; reason text; tz text;
begin
  select * into i from provider_instances where instance_name = p_instance and active for update;
  if i.id is null or i.paused or i.state <> 'open' then return; end if;
  if i.last_claimed_at is not null and i.last_claimed_at > p_now - make_interval(secs => i.min_gap_seconds) then return; end if;
  tz := setting_text(i.workspace_id, 'timezone', 'America/Sao_Paulo');
  select count(*) into n_min from outbound_messages where provider_instance = p_instance and claimed_at > p_now - interval '60 seconds';
  select count(*) into n_day from outbound_messages where provider_instance = p_instance
     and claimed_at >= ((p_now at time zone tz)::date)::timestamp at time zone tz;
  allow := least(p_limit, i.rate_per_minute - n_min, i.daily_cap - n_day);
  if allow <= 0 then return; end if;

  for m in select * from outbound_messages where workspace_id = i.workspace_id and status = 'queued' and next_attempt_at <= p_now
           order by priority, queued_at limit 50 for update skip locked loop
    reason := case
      when m.ttl_at <= p_now then 'ttl'
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

-- Resultado do envio devolvido pelo adapter.
create or replace function mark_outbound_result(p_id uuid, p_ok boolean, p_provider_message_id text default null,
  p_error_code text default null, p_retryable boolean default false, p_uncertain boolean default false,
  p_now timestamptz default now())
returns text language plpgsql as $$
declare m outbound_messages; conv uuid; n_err int; backoff int[] := array[1, 5, 15]; newst text;
begin
  select * into m from outbound_messages where id = p_id for update;
  if m.id is null then return 'not_found'; end if;
  if p_ok then
    update outbound_messages set status = case when status in ('delivered','read') then status else 'sent' end,
           provider_message_id = coalesce(provider_message_id, p_provider_message_id), sent_at = coalesce(sent_at, p_now),
           last_error_code = null where id = p_id;
    insert into conversations(workspace_id, contact_id) values (m.workspace_id, m.contact_id) on conflict (contact_id) do nothing;
    select id into conv from conversations where contact_id = m.contact_id;
    insert into messages(workspace_id, contact_id, conversation_id, direction, provider, provider_instance, provider_message_id,
                         from_me, origin, type, text, outbound_id, occurred_at)
    values (m.workspace_id, m.contact_id, conv, 'out', coalesce(m.provider, 'evolution'), m.provider_instance,
            coalesce(p_provider_message_id, 'noid:' || m.id), true, 'engine', 'text', m.rendered_body, m.id, p_now)
    on conflict (provider, provider_message_id) do update set outbound_id = excluded.outbound_id, origin = 'engine';
    update conversations set last_outbound_at = p_now where id = conv;
    return 'sent';
  end if;

  insert into message_status_events(provider, provider_message_id, status, at, raw)
  values (coalesce(m.provider, 'evolution'), 'outbound:' || m.id, 'send_error', p_now,
          jsonb_build_object('code', p_error_code, 'instance', m.provider_instance));

  if p_uncertain then
    newst := 'uncertain';
  elsif p_retryable and m.attempts < m.max_attempts then
    newst := 'queued';
  elsif p_retryable then
    newst := 'dead';
  else
    newst := 'failed';
  end if;
  update outbound_messages set status = newst, last_error_code = p_error_code,
         next_attempt_at = case when newst = 'queued' then p_now + make_interval(mins => backoff[least(m.attempts, 3)]) else next_attempt_at end,
         failed_at = case when newst in ('failed','dead') then p_now else failed_at end
   where id = p_id;
  if newst = 'dead' then
    perform raise_alert(m.workspace_id, 'message_dead', 'warn',
      'Mensagem não enviada após ' || m.attempts || ' tentativas (' || m.template_key || ', erro ' || coalesce(p_error_code, '?') || ')', 'dead:' || m.id);
  end if;

  -- rajada de erros → pausa a instância
  select count(*) into n_err from message_status_events
   where status = 'send_error' and at > p_now - interval '5 minutes' and raw ->> 'instance' = m.provider_instance;
  if n_err >= 3 then
    update provider_instances set paused = true, pause_reason = 'error_burst'
     where instance_name = m.provider_instance and not paused;
    if found then
      perform raise_alert(m.workspace_id, 'instance_error_burst', 'critical',
        '🟠 ' || n_err || ' erros de envio em 5 min em ' || m.provider_instance || '. Envios PAUSADOS até liberação manual.',
        'burst:' || m.provider_instance || ':' || to_char(p_now, 'YYYYMMDDHH24MI'));
    end if;
  end if;
  return newst;
end $$;

-- Mensagens travadas: 'sending' > 3 min → incerto; incerto > 6 min sem eco → 1 retentativa ou 'dead'.
create or replace function reap_outbound(p_now timestamptz default now())
returns jsonb language plpgsql as $$
declare n1 int; n2 int; n3 int;
begin
  update outbound_messages set status = 'uncertain', status_reason = 'stuck_sending'
   where status = 'sending' and claimed_at < p_now - interval '3 minutes';
  get diagnostics n1 = row_count;
  update outbound_messages set status = 'queued', next_attempt_at = p_now, status_reason = 'retry_after_uncertain'
   where status = 'uncertain' and claimed_at < p_now - interval '6 minutes' and attempts < max_attempts and ttl_at > p_now;
  get diagnostics n2 = row_count;
  update outbound_messages set status = 'dead', status_reason = 'uncertain_exhausted', failed_at = p_now
   where status = 'uncertain' and claimed_at < p_now - interval '6 minutes';
  get diagnostics n3 = row_count;
  return jsonb_build_object('to_uncertain', n1, 'requeued', n2, 'dead', n3);
end $$;

-- Liberação manual da instância (ativação inicial ou após rajada de erros).
create or replace function unpause_instance(p_instance text, p_by text, p_now timestamptz default now())
returns void language plpgsql as $$
declare i provider_instances;
begin
  update provider_instances set paused = false, pause_reason = null where instance_name = p_instance returning * into i;
  perform raise_alert(i.workspace_id, 'instance_unpaused', 'info', '▶️ Envios liberados em ' || p_instance || ' por ' || p_by, null);
end $$;

-- ═══ Checagem pré-envio / reconciliação com a API da GGCheckout ══════════════
create or replace function reconcile_gg_payment(p_ws_slug text, p_external_id text, p_status text,
                                                p_paid_at timestamptz default null, p_now timestamptz default now())
returns text language plpgsql as $$
declare ws uuid := ws_id(p_ws_slug); st text; cur text;
begin
  st := case lower(p_status) when 'paid' then 'paid' when 'refunded' then 'refunded' when 'chargeback' then 'chargeback'
          when 'charged_back' then 'chargeback' when 'cancelled' then 'expired' when 'expired' then 'expired'
          when 'pending' then 'pending' when 'error' then 'failed' else null end;
  if st is null then return 'ignored'; end if;
  select status into cur from orders where workspace_id = ws and external_id = p_external_id;
  if cur is null then
    -- webhook nunca chegou: registra sem contato (a API mascara os dados pessoais)
    perform apply_order_status(ws, p_external_id, st, coalesce(p_paid_at, p_now), 'reconcile', null, '{}'::jsonb, null, p_now);
    return 'inserted';
  end if;
  if status_rank(st) > status_rank(cur) then
    perform apply_order_status(ws, p_external_id, st, coalesce(p_paid_at, p_now), 'reconcile', null, '{}'::jsonb, null, p_now);
    perform raise_alert(ws, 'reconcile_fix', 'info', 'Reconciliação corrigiu pedido ' || p_external_id || ': ' || cur || ' → ' || st,
                        'recfix:' || p_external_id || ':' || st);
    return 'updated';
  end if;
  return 'unchanged';
end $$;

-- Reembolso feito fora da GGCheckout (manual).
create or replace function register_manual_refund(p_ws_slug text, p_external_id text, p_by text, p_now timestamptz default now())
returns text language plpgsql as $$
declare ws uuid := ws_id(p_ws_slug);
begin
  if not exists (select 1 from orders where workspace_id = ws and external_id = p_external_id) then return 'order_not_found'; end if;
  perform apply_order_status(ws, p_external_id, 'refunded', p_now, 'manual:' || p_by, null, '{}'::jsonb, null, p_now);
  return 'refunded';
end $$;

-- ═══ IA: reservar conversas prontas (debounce) e registrar resultado ═════════
create or replace function claim_ai_work(p_ws_slug text, p_debounce_seconds int default 20, p_limit int default 5,
                                         p_now timestamptz default now())
returns setof jsonb language plpgsql as $$
declare ws uuid := ws_id(p_ws_slug); cv conversations; c contacts; hrs jsonb; tz text;
begin
  hrs := setting(ws, 'handoff_hours'); tz := setting_text(ws, 'timezone', 'America/Sao_Paulo');
  for cv in select * from conversations where workspace_id = ws and ai_pending_since is not null
             and ai_pending_since <= p_now - make_interval(secs => p_debounce_seconds)
             order by ai_pending_since limit p_limit for update skip locked loop
    update conversations set ai_pending_since = null where id = cv.id;
    select * into c from contacts where id = cv.contact_id;
    if c.opted_out_at is not null or contact_in_human_mode(c.id, p_now) then continue; end if;
    return next jsonb_build_object(
      'contact_id', c.id, 'phone', c.phone_e164, 'first_name', first_name(c.name),
      'human_hours_open', in_window(p_now, tz, (hrs ->> 'start')::time, (hrs ->> 'end')::time),
      'human_hours', (hrs ->> 'start') || '–' || (hrs ->> 'end'),
      'now_local', to_char(p_now at time zone tz, 'YYYY-MM-DD HH24:MI'),
      'ai', coalesce(setting(ws, 'ai'), '{}'::jsonb),
      'pending', (select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'text', m.text, 'at', m.occurred_at) order by m.occurred_at), '[]')
                    from messages m where m.contact_id = c.id and m.origin = 'customer' and m.answered_by_ai_at is null),
      'history', (select coalesce(jsonb_agg(x order by x ->> 'at'), '[]') from (
                    select jsonb_build_object('role', case when m.direction = 'in' then 'cliente' else 'empresa' end,
                                              'text', m.text, 'at', m.occurred_at) x
                      from messages m
                     where m.contact_id = c.id and not (m.origin = 'customer' and m.answered_by_ai_at is null)
                     order by m.occurred_at desc limit 12) h),
      'orders', (select coalesce(jsonb_agg(jsonb_build_object('produto', coalesce(p.title, o.offer_title), 'status', o.status,
                    'metodo', o.payment_method, 'criado', to_char(o.created_at at time zone tz, 'DD/MM HH24:MI'),
                    'link_acesso', case when o.status = 'paid' then p.access_url end) order by o.created_at desc), '[]')
                  from orders o left join catalog_products p on p.workspace_id = o.workspace_id and p.external_product_id = o.external_product_id
                  where o.contact_id = c.id and o.created_at > p_now - interval '60 days'),
      'kb', (select coalesce(jsonb_agg(jsonb_build_object('slug', k.slug, 'title', k.title, 'answer', k.answer) order by k.slug), '[]')
               from kb_articles k where k.workspace_id = ws and k.active and k.approved_by is not null));
  end loop;
end $$;

create or replace function record_ai_result(p_ws_slug text, p_contact uuid, p_inbound_ids uuid[], p_decision text,
  p_reply text, p_kb_slugs text[], p_handoff_reason text, p_model text, p_stop_reason text,
  p_tokens_in int, p_tokens_out int, p_latency_ms int, p_now timestamptz default now())
returns jsonb language plpgsql as $$
declare ws uuid := ws_id(p_ws_slug); dec text := p_decision; why text := p_handoff_reason; run uuid; h handoffs; oid uuid;
        valid_slugs text[];
begin
  select coalesce(array_agg(slug), '{}') into valid_slugs from kb_articles
   where workspace_id = ws and active and approved_by is not null and slug = any (coalesce(p_kb_slugs, '{}'));
  -- guardrails determinísticos sobre a saída da IA
  if dec = 'reply' and (coalesce(array_length(valid_slugs, 1), 0) = 0) then dec := 'handoff'; why := 'sem cobertura na base'; end if;
  if dec = 'reply' and (p_reply is null or length(trim(p_reply)) = 0 or length(p_reply) > 1200) then dec := 'handoff'; why := 'resposta inválida'; end if;
  if dec not in ('reply','handoff') then dec := 'handoff'; why := coalesce(why, 'erro da IA'); end if;

  insert into agent_runs(workspace_id, contact_id, inbound_ids, decision, reply_text, kb_slugs, handoff_reason, model,
                         stop_reason, tokens_in, tokens_out, latency_ms, created_at)
  values (ws, p_contact, coalesce(p_inbound_ids, '{}'), case when p_decision = 'error' then 'error' else dec end,
          p_reply, valid_slugs, why, p_model, p_stop_reason, p_tokens_in, p_tokens_out, p_latency_ms, p_now)
  returning id into run;
  update messages set answered_by_ai_at = p_now where id = any (coalesce(p_inbound_ids, '{}'));

  if dec = 'reply' then
    oid := enqueue_message(ws, p_contact, 'support', 'ia_resposta', jsonb_build_object('texto', trim(p_reply)),
                           'ai:' || run, '{}'::jsonb, 'agent_run', run::text, 2, p_now);
    return jsonb_build_object('decision', 'reply', 'outbound_id', oid, 'run_id', run);
  end if;

  h := start_handoff(ws, p_contact, why, 'ai', left(p_reply, 300), p_now);
  oid := enqueue_message(ws, p_contact, 'handoff_notice', case when h.status = 'open' then 'handoff_aberto' else 'handoff_fila' end,
                         '{}'::jsonb, 'handoff_notice:' || h.id, '{}'::jsonb, 'handoff', h.id::text, 2, p_now);
  return jsonb_build_object('decision', 'handoff', 'handoff_status', h.status, 'outbound_id', oid, 'run_id', run);
end $$;

-- ═══ Vigia (alertas operacionais) ════════════════════════════════════════════
create or replace function watchdog(p_ws_slug text, p_now timestamptz default now())
returns jsonb language plpgsql as $$
declare ws uuid := ws_id(p_ws_slug); tz text := setting_text(ws, 'timezone', 'America/Sao_Paulo'); lt time; n int;
begin
  lt := (p_now at time zone tz)::time;
  -- nenhum webhook da GGCheckout em 2h entre 08h e 23h
  if lt between '08:00' and '23:00' and not exists (select 1 from webhook_inbox where workspace_id = ws and source = 'ggcheckout'
       and received_at > p_now - interval '2 hours') and exists (select 1 from webhook_inbox where workspace_id = ws and source = 'ggcheckout') then
    perform raise_alert(ws, 'no_gg_webhooks', 'warn', '⚠️ Nenhum evento da GGCheckout nas últimas 2h. Webhook caiu?',
                        'nogg:' || to_char(p_now, 'YYYYMMDDHH24'));
  end if;
  -- health check da instância parado há > 5 min
  if exists (select 1 from provider_instances where workspace_id = ws and active
            and (last_health_check_at is null or last_health_check_at < p_now - interval '5 minutes')) then
    perform raise_alert(ws, 'health_stale', 'warn', '⚠️ Health check do WhatsApp sem rodar há mais de 5 min (n8n parado?)',
                        'health:' || to_char(p_now, 'YYYYMMDDHH24'));
  end if;
  -- fila acumulando com instância pausada
  select count(*) into n from outbound_messages where workspace_id = ws and status = 'queued' and queued_at < p_now - interval '15 minutes';
  if n > 0 then
    perform raise_alert(ws, 'queue_stale', 'warn', '⚠️ ' || n || ' mensagens na fila há mais de 15 min.',
                        'qstale:' || to_char(p_now, 'YYYYMMDDHH24'));
  end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function claim_alerts(p_limit int default 10, p_now timestamptz default now())
returns setof alerts language sql as $$
  update alerts set attempts = attempts + 1, claimed_at = p_now
   where id in (select id from alerts where sent_at is null and attempts < 5
                  and (claimed_at is null or claimed_at < p_now - interval '2 minutes')
                order by id limit p_limit for update skip locked)
  returning *;
$$;

create or replace function mark_alert_sent(p_id bigint, p_now timestamptz default now())
returns void language sql as $$ update alerts set sent_at = p_now where id = p_id $$;


-- Cancela uma mensagem já reservada (ex.: checagem pré-envio na GGCheckout mostrou que pagou).
create or replace function cancel_outbound(p_id uuid, p_reason text) returns void
language sql as $$
  update outbound_messages set status = 'cancelled', status_reason = p_reason
   where id = p_id and status in ('sending','queued','uncertain')
$$;

-- Reconciliação em lote (lista de pagamentos da API da GGCheckout).
create or replace function reconcile_gg_batch(p_ws_slug text, p_items jsonb, p_now timestamptz default now())
returns jsonb language plpgsql as $$
declare it jsonb; r text; res jsonb := '{}'::jsonb;
begin
  for it in select * from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) loop
    r := reconcile_gg_payment(p_ws_slug, it ->> 'id', it ->> 'status', nullif(it ->> 'paid_at', '')::timestamptz, p_now);
    res := jsonb_set(res, array[r], to_jsonb(coalesce((res ->> r)::int, 0) + 1));
  end loop;
  return res;
end $$;

-- ═══ Permissões: RPC só para service_role ════════════════════════════════════
do $$
declare f record;
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' loop
      execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    end loop;
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on all functions in schema public to service_role';
    execute 'grant all on all tables in schema public to service_role';
    execute 'grant all on all sequences in schema public to service_role';
  end if;
end $$;
