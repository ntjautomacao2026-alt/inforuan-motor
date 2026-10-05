-- INFORUAN — 0009: limites de sessão do n8n_engine, antes de liberar o login.
-- NÃO libera login e NÃO define senha. O login é liberado à parte, pelo operador, com a senha já cifrada
-- (SCRAM-SHA-256) gerada no Mac: a senha em texto puro nunca chega ao Supabase nem a arquivo versionado.
-- Os limites valem para cada nova sessão do role (inclusive via pooler em modo sessão).

alter role n8n_engine connection limit 10;
alter role n8n_engine set statement_timeout = '15s';                  -- nenhuma chamada da api deve passar disso
alter role n8n_engine set lock_timeout = '5s';                        -- não fica preso esperando lock
alter role n8n_engine set idle_in_transaction_session_timeout = '60s'; -- transação esquecida não segura locks
