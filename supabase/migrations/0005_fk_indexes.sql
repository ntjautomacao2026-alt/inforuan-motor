-- INFORUAN — 0005: índices das chaves estrangeiras apontadas pela auditoria de desempenho.
-- Idempotente (IF NOT EXISTS).
create index if not exists agent_runs_contact_ix            on agent_runs(contact_id);
create index if not exists agent_runs_workspace_ix          on agent_runs(workspace_id);
create index if not exists conversations_workspace_ix       on conversations(workspace_id);
create index if not exists enrollments_order_ix             on enrollments(order_id);
create index if not exists enrollments_workspace_ix         on enrollments(workspace_id);
create index if not exists events_inbox_ix                  on events(inbox_id);
create index if not exists events_order_ix                  on events(order_id);
create index if not exists experiment_assignments_contact_ix on experiment_assignments(contact_id);
create index if not exists handoffs_workspace_ix            on handoffs(workspace_id);
create index if not exists messages_conversation_ix         on messages(conversation_id);
create index if not exists messages_outbound_ix             on messages(outbound_id);
create index if not exists messages_workspace_ix            on messages(workspace_id);
create index if not exists outbound_messages_workspace_ix   on outbound_messages(workspace_id);
create index if not exists provider_instances_workspace_ix  on provider_instances(workspace_id);
create index if not exists scheduled_actions_contact_ix     on scheduled_actions(contact_id);
create index if not exists scheduled_actions_order_ix       on scheduled_actions(order_id);
create index if not exists scheduled_actions_step_ix        on scheduled_actions(step_id);
create index if not exists webhook_inbox_workspace_ix       on webhook_inbox(workspace_id);
