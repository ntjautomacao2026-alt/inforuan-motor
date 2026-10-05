-- INFORUAN — 0010: porta de entrada dos webhooks da GGCheckout (usada pela Edge Function gg-webhook).
-- A Edge Function só autentica e repassa; as regras ficam aqui:
-- • modo só internos (engine_mode <> 'live'): evento de cliente real é DESCARTADO sem gravar payload nem dado pessoal
--   (fica só um evento de contagem com o tipo do evento e o checkout); entram só o checkout de teste e telefones internos;
-- • limite por minuto (settings.gg_webhook_rate_per_minute, padrão 120): acima disso responde rate_limited + alerta;
-- • deduplicação (event | payment.id | status) e processamento imediato (o pg_cron cobre qualquer falha).
-- Só service_role executa. n8n_engine, anon e authenticated não.

insert into settings(workspace_id, key, value)
select id, 'gg_webhook_rate_per_minute', '120' from workspaces where slug = 'inforuan'
on conflict (workspace_id, key) do nothing;

create index if not exists webhook_inbox_source_received_ix on webhook_inbox(source, received_at);

create or replace function ingest_gg_webhook(p_headers jsonb, p_payload jsonb, p_now timestamptz default now())
returns jsonb language plpgsql as $$
declare ws uuid := ws_id('inforuan'); ev text; pid text; st text; ck text; ph text; internal boolean;
        lim int; n int; res jsonb;
begin
  ev  := lower(coalesce(p_payload ->> 'event', ''));
  pid := coalesce(p_payload #>> '{payment,id}', p_payload ->> 'id');
  st  := lower(coalesce(p_payload #>> '{payment,status}', ''));
  if pid is null or length(pid) = 0 or length(pid) > 200 or ev = '' then
    return jsonb_build_object('accepted', false, 'reason', 'invalid_payload');
  end if;

  if not engine_live(ws) then
    ck := coalesce(p_payload ->> 'checkoutId', p_payload #>> '{payment,checkoutId}', p_payload #>> '{metadata,checkoutId}');
    ph := norm_phone_br(coalesce(p_payload #>> '{customer,phone}', p_payload ->> 'phone'));
    internal := exists (select 1 from catalog_checkouts where workspace_id = ws and is_internal_test and external_checkout_id = ck)
             or (ph is not null and coalesce(setting(ws, 'internal_test_phones') ? ph, false));
    if not internal then
      insert into events(workspace_id, type, occurred_at, source, payload)
      values (ws, 'gg.ignored_internal_only', p_now, 'ggcheckout', jsonb_build_object('event', ev, 'checkout_id', ck));
      return jsonb_build_object('accepted', false, 'reason', 'internal_only');
    end if;
  end if;

  lim := coalesce((setting(ws, 'gg_webhook_rate_per_minute') #>> '{}')::int, 120);
  select count(*) into n from webhook_inbox where source = 'ggcheckout' and received_at > p_now - interval '1 minute';
  if n >= lim then
    perform raise_alert(ws, 'gg_webhook_rate_limited', 'critical',
      '🔴 Webhook da GGCheckout acima de ' || lim || '/min. Excedentes recusados (a GGCheckout reenvia e a reconciliação cobre).',
      'ggrate:' || to_char(p_now, 'YYYYMMDDHH24MI'));
    return jsonb_build_object('accepted', false, 'reason', 'rate_limited');
  end if;

  res := ingest_webhook('inforuan', 'ggcheckout', ev || '|' || pid || '|' || st, ev, coalesce(p_headers, '{}'::jsonb), p_payload);
  update webhook_inbox set received_at = p_now where id = (res ->> 'inbox_id')::bigint;
  perform process_pending_inbox(20, p_now);
  return jsonb_build_object('accepted', true, 'duplicate', (res ->> 'duplicate')::boolean);
end $$;

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname = 'ingest_gg_webhook' loop
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
