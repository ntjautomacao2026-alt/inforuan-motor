-- INFORUAN — 0003: visões de medição.

-- Holdout da régua de Pix, por INTENÇÃO DE TRATAR.
-- Unidade: contato (1ª matrícula no experimento). Elegível: Pix ainda não pago no instante eligible_at (T+6 min).
-- Conversão: qualquer pedido pago do contato em (eligible_at, eligible_at + janela]. Só janelas já encerradas contam.
-- Contatos internos ficam fora.
create or replace view v_recovery_holdout as
with first_enr as (
  select distinct on (e.contact_id) e.contact_id, e.arm, e.eligible_at, e.order_id, x.window_hours, x.key as experiment_key
    from enrollments e
    join sequences s on s.id = e.sequence_id
    join experiments x on x.workspace_id = e.workspace_id and x.key = s.experiment_key
   where not e.is_internal_test
   order by e.contact_id, e.eligible_at
), elig as (
  select f.* from first_enr f join orders o on o.id = f.order_id
   where o.paid_at is null or o.paid_at > f.eligible_at
), outcome as (
  select el.experiment_key, el.arm, el.contact_id,
         (el.eligible_at + make_interval(hours => el.window_hours)) <= now() as window_closed,
         coalesce((select sum(p.amount_cents) from orders p
                    where p.contact_id = el.contact_id and p.paid_at > el.eligible_at
                      and p.paid_at <= el.eligible_at + make_interval(hours => el.window_hours)), 0) as revenue_cents
    from elig el
)
select experiment_key, arm,
       count(*)                                                   as eligible_total,
       count(*) filter (where window_closed)                      as eligible_closed,
       count(*) filter (where window_closed and revenue_cents > 0) as converted,
       round(100.0 * count(*) filter (where window_closed and revenue_cents > 0)
             / nullif(count(*) filter (where window_closed), 0), 2) as conversion_pct,
       round(sum(revenue_cents) filter (where window_closed)::numeric
             / nullif(count(*) filter (where window_closed), 0), 0) as revenue_per_eligible_cents
  from outcome
 group by experiment_key, arm;

-- Lift: receita incremental = (receita/elegível tratado − receita/elegível controle) × elegíveis tratados.
create or replace view v_recovery_lift as
select t.experiment_key,
       t.eligible_closed as treated, c.eligible_closed as control,
       t.conversion_pct as treated_pct, c.conversion_pct as control_pct,
       t.conversion_pct - c.conversion_pct as lift_pp,
       round((t.revenue_per_eligible_cents - c.revenue_per_eligible_cents) * t.eligible_closed / 100.0, 2) as incremental_revenue_brl
  from v_recovery_holdout t join v_recovery_holdout c on c.experiment_key = t.experiment_key and c.arm = 'control'
 where t.arm = 'treatment';

-- Operação diária de mensagens
create or replace view v_messages_daily as
select (queued_at at time zone 'America/Sao_Paulo')::date as dia, purpose, template_key, status, count(*) as n
  from outbound_messages where not is_internal_test
 group by 1, 2, 3, 4;

-- Handoffs ativos (para a equipe)
create or replace view v_handoffs_active as
select h.id, c.name, c.phone_e164, h.reason, h.origin, h.status, h.started_at, h.expires_at
  from handoffs h join contacts c on c.id = h.contact_id
 where h.status in ('open','queued') and h.expires_at > now();

alter view v_recovery_holdout set (security_invoker = on);
alter view v_recovery_lift set (security_invoker = on);
alter view v_messages_daily set (security_invoker = on);
alter view v_handoffs_active set (security_invoker = on);
