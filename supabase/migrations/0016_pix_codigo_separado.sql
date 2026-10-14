-- INFORUAN — 0016: texto do passo 1 aprovado pelo Ruan (14/10/2026) + código Pix numa mensagem separada.
-- Pedido do Ruan: público 40+ → o código Pix vai SOZINHO numa 2ª mensagem, para copiar com um toque longo.
-- • pix_ativo v2: texto aprovado, sem o código (avisa que o código vem logo abaixo).
-- • pix_codigo v1: só {{pix_code}}. Enfileirado junto, 1 ms depois, mesma prioridade, mesmo guard e validade.
--   São 2 mensagens independentes (cada uma com seu id): o eco da 2ª não vira "resposta humana".
-- • Passo 1 sem código Pix no pedido é pulado (missing_pix_code) — nunca manda "o código vem abaixo" sem código.
-- • Intervalo mínimo da inforuan-01: 30 s → 5 s (o código chega ~15 s depois do texto); 2/min e 40/dia mantidos.

insert into message_templates(workspace_id, key, version, purpose, ttl_minutes, required_vars, body_text, meta_category)
select id, 'pix_ativo', 2, 'recovery', 8, array['nome','produto'],
       E'Oi, {{nome}}! Vi que você gerou o Pix do *{{produto}}* e ele ainda está ativo por alguns minutos.\n\nPara concluir, copie o código que vou mandar logo abaixo e cole no app do seu banco, em *Pix Copia e Cola*.\n\nSe tiver qualquer dúvida, é só responder aqui.',
       'utility'
from workspaces where slug = 'inforuan'
on conflict (workspace_id, key, version) do nothing;

insert into message_templates(workspace_id, key, version, purpose, ttl_minutes, required_vars, body_text, meta_category)
select id, 'pix_codigo', 1, 'recovery', 8, array['pix_code'], E'{{pix_code}}', 'utility'
from workspaces where slug = 'inforuan'
on conflict (workspace_id, key, version) do nothing;

update message_templates set active = false
 where key = 'pix_ativo' and version = 1 and workspace_id = (select id from workspaces where slug = 'inforuan');

update provider_instances set min_gap_seconds = 5 where instance_name = 'inforuan-01';

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
      when st.template_key = 'pix_ativo' and o.pix_code is null then 'missing_pix_code'   -- 0016
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
      -- 0016: o código Pix vai numa 2ª mensagem, sozinho (público 40+: copiar com um toque longo).
      -- Mesma prioridade, 1 ms depois → sai logo após o texto; guard e validade iguais (se pagar, não sai).
      if oid is not null and st.template_key = 'pix_ativo' then
        perform enqueue_message(ws, c.id, 'recovery', 'pix_codigo', jsonb_build_object('pix_code', o.pix_code),
                 'recovery:' || o.id || ':step:' || st.position || ':codigo',
                 jsonb_build_object('order_unpaid', o.id, 'order_external_id', o.external_id),
                 'enrollment', e.id::text, 5, p_now + interval '1 millisecond');
      end if;
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
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname = 'dispatch_due_actions' loop
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
