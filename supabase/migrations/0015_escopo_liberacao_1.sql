-- INFORUAN — 0015: escopo da 1ª liberação para clientes reais (decisão de 14/10/2026).
-- • Liga só a recuperação, PASSO 1 ("Pix ainda válido", T+6 min, com o código Pix): é o que mais recupera e cabe
--   no limite de aquecimento (40/dia). Passos 2–4 desligados (também dependem dos links públicos dos checkouts).
-- • Pós-venda pelo WhatsApp desligado por enquanto (o e-mail de entrega da GGCheckout continua para todos).
--   Religar: update settings set value = '"on"' where key = 'post_purchase_whatsapp';
-- • NÃO muda o modo do motor: continua 'internal_only' até set_engine_mode('inforuan', 'live', …) com autorização.

insert into settings(workspace_id, key, value)
select id, 'post_purchase_whatsapp', '"off"' from workspaces where slug = 'inforuan'
on conflict (workspace_id, key) do update set value = excluded.value, updated_at = now();

update sequence_steps st set active = (st.position = 1)
  from sequences s
 where s.id = st.sequence_id and s.key = 'recovery_pix'
   and s.workspace_id = (select id from workspaces where slug = 'inforuan');

create or replace function on_order_paid(p_ws uuid, p_order uuid, p_now timestamptz) returns void
language plpgsql as $$
declare o orders; p catalog_products; c contacts;
begin
  select * into o from orders where id = p_order;
  if o.contact_id is null then return; end if;
  perform cancel_recovery_for_contact(o.contact_id, 'paid', p_now);
  select * into c from contacts where id = o.contact_id;
  if c.phone_e164 is null then return; end if;
  -- 0015: pós-venda pelo WhatsApp pode ser desligado (o e-mail da GGCheckout continua). Padrão: ligado.
  if setting_text(p_ws, 'post_purchase_whatsapp', 'on') <> 'on' then return; end if;
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

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname = 'on_order_paid' loop
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
