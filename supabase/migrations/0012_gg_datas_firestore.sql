-- INFORUAN — 0012: datas da GGCheckout no formato real (descoberto no 1º evento real, 14/10/2026).
-- O webhook manda createdAt como objeto Firestore {"_seconds": ..., "_nanoseconds": ...}, não como texto ISO.
-- gg_ts() aceita os dois formatos (e devolve NULL para qualquer outro, sem quebrar o processamento).
-- Observação: o payload real NÃO traz checkoutId (nem no topo, nem em payment/metadata); enriquecer pela API depois.

create or replace function gg_ts(p jsonb) returns timestamptz language plpgsql immutable as $$
begin
  if p is null or jsonb_typeof(p) = 'null' then return null; end if;
  if jsonb_typeof(p) = 'object' and p ? '_seconds' then
    return to_timestamp((p ->> '_seconds')::double precision + coalesce((p ->> '_nanoseconds')::double precision, 0) / 1e9);
  end if;
  if jsonb_typeof(p) = 'string' then
    return (p #>> '{}')::timestamptz;
  end if;
  return null;
exception when others then
  return null;
end $$;

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
  occurred := coalesce(gg_ts(p_payload -> 'createdAt'), p_now);   -- 0012: aceita o formato Firestore
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

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname in ('gg_ts', 'process_gg_payload') loop
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
