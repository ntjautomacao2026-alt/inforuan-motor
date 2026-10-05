-- COLE TUDO NO SQL EDITOR DO SUPABASE (projeto bsmuouivezjnfrcnamky) E CLIQUE EM RUN.
-- Conteúdo idêntico a supabase/migrations/0008_pg_cron.sql + registro no histórico.
-- (A 0007 já foi aplicada pelo MCP em 05/10/2026.) Tudo ou nada: se algo falhar, nada é aplicado.
begin;
-- INFORUAN — 0008: agendamentos no próprio banco (pg_cron). SÓ no Supabase (não roda no PGlite).
-- Substitui o IR-03 (motor) e a parte de banco do IR-07 (handoffs + vigia). pg_net NÃO é instalado.
-- Com o modo 'internal_only' (0007), a régua inativa e a instância simulada pausada, estes jobs não enviam nada:
-- só processam o que chegar na inbox e mantêm o estado em dia.
-- Horários do cron em UTC. Idempotente: cron.schedule com o mesmo nome atualiza o job.

create extension if not exists pg_cron with schema pg_catalog;

select cron.schedule('inforuan-tick', '30 seconds',
  $job$select public.engine_tick('inforuan')$job$);

select cron.schedule('inforuan-housekeeping', '*/5 * * * *',
  $job$select public.engine_housekeeping('inforuan')$job$);

-- 06:30 UTC = 03:30 em São Paulo: retenção de 30 dias + limpeza do histórico de execuções do próprio cron (7 dias).
select cron.schedule('inforuan-maintenance', '30 6 * * *',
  $job$select public.purge_retention(30); delete from cron.job_run_details where end_time < now() - interval '7 days'$job$);

-- Registro no histórico (para aparecer junto das migrações 0001–0007)
insert into supabase_migrations.schema_migrations(version, name, created_by)
values ('20261005190100', '0008_pg_cron', 'ntjautomacao (sql editor)')
on conflict (version) do nothing;
commit;

-- Conferência: deve listar os 3 jobs inforuan-* ativos.
select jobname, schedule, active from cron.job where jobname like 'inforuan-%' order by jobname;
