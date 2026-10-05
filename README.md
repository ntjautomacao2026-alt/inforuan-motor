# INFORUAN — Motor de monetização (fase 1: recuperação de Pix, pós-venda e atendimento)

Núcleo **Supabase (estado, regras críticas e agendamentos via `pg_cron`) + n8n self-hosted (integrações externas: IA, alertas, GGCheckout)**. O n8n só fala com o motor pelo schema `api`, como `n8n_engine`. Toda saída passa por uma camada única de envio; o **provedor de WhatsApp ainda não foi escolhido** (testes usam o provedor `simulated`, dentro do banco).
**Comece por [`docs/00-visao-geral-e-retomada.md`](docs/00-visao-geral-e-retomada.md).** Arquitetura e decisões em [`docs/`](docs/). **Nada está ativo.**

## Estrutura
| Caminho | O que é |
|---|---|
| `supabase/migrations/0001_core.sql` | Tabelas (RLS fechado; só `service_role`) |
| `supabase/migrations/0002_functions.sql` | Regras do motor: ingestão idempotente, status monotônico, "pagou → para", régua, holdout, camada de envio (fila, limites, pausa, TTL, retentativa, incerteza), handoff explícito, IA, reconciliação, alertas |
| `supabase/migrations/0003_views.sql` | Medição do holdout (intenção de tratar), lift, operação |
| `supabase/migrations/0004_hardening.sql` | Só `service_role`; `search_path` fixo nas funções |
| `supabase/migrations/0005_fk_indexes.sql` | Índices das chaves estrangeiras (idempotente) |
| `supabase/migrations/0006_api_interface.sql` | Schema `api` (única interface do n8n), role `n8n_engine` (NOLOGIN), retenção de 30 dias, heartbeat |
| `supabase/manual/0006_aplicar_no_sql_editor.sql` | Mesma 0006 em transação + registro no histórico (foi aplicada pelo SQL Editor) |
| `supabase/migrations/0007_modo_interno.sql` | Modo **só internos** (padrão), provedor `simulated` (`inforuan-sim`, pausado), `engine_tick` / `engine_housekeeping` |
| `supabase/migrations/0008_pg_cron.sql` | `pg_cron`: tick a cada 30 s, handoffs + vigia a cada 5 min, retenção diária (só Supabase) |
| `supabase/manual/0008_aplicar_no_sql_editor.sql` | Mesma 0008 em transação + registro no histórico (foi aplicada pelo SQL Editor) |
| `supabase/manual/0007_0008_reverter.sql` | Reversão: desliga os jobs (passo 1) e, se preciso, volta as funções originais (passo 2) |
| `supabase/migrations/0009_n8n_engine_limites.sql` | Limites de sessão do `n8n_engine` (10 conexões; timeouts). Não libera login |
| `ops/gerar-senha-n8n-engine.mjs` | Gera a senha do `n8n_engine` no Mac (Keychain) e copia o SQL com a senha já cifrada (SCRAM) |
| `ops/testar-n8n-engine.mjs` | Testa o login pelo pooler com TLS verificado e os bloqueios de permissão (lê a senha do Keychain; não a exibe) |
| `infra/certs/supabase-prod-ca-2021.crt` | CA pública do Supabase, para verificar o certificado do pooler |
| `supabase/migrations/0010_ingestao_gg.sql` | `ingest_gg_webhook`: só internos (descarta cliente real sem dados), limite por minuto, deduplicação, processamento imediato |
| `supabase/functions/gg-webhook/` | Edge Function de entrada da GGCheckout (segredo Bearer/x-secret/HMAC, 64 KB, logs sem dados). Doc 18 |
| `ops/gerar-segredo-gg-webhook.mjs` / `ops/testar-gg-webhook.mjs` | Segredo do webhook no Keychain; teste da função publicada sem dado pessoal |
| `supabase/seed/0001_config.sql` | Config inicial segura: **régua inativa, nenhuma instância de envio** (provedor a decidir), holdout 10%, templates-rascunho |
| `supabase/seed/0002_catalog_links.local.sql` | Links de entrega atuais (não versionar) + links públicos dos checkouts (a preencher) |
| `n8n/build.mjs` → `n8n/dist/*.json` | Workflows importáveis (IR-05, IR-06, IR-08), todos `active=false`, só via `api.*` (credencial Postgres do `n8n_engine`) |
| `prompts/atendimento-system.md` | Prompt do atendimento (IA limitada à base) |
| `tests/engine.test.mjs` | 37 testes: regras críticas no Postgres real (PGlite) + o SQL de cada nó dos workflows rodando como `n8n_engine` |
| `tests/gg-webhook.test.mjs` | 8 testes da Edge Function (HTTP + banco real) |
| `ops/evolution-checklist.md` | (Só se o provedor escolhido for a Evolution) webhook global, instância, coexistência |

## Testes
```bash
npm install && npm test
```

## Workflows n8n
| WF | Gatilho | Função |
|---|---|---|
| IR-05 | A cada 10 s | `api.claim_ai_work` (debounce 20 s) → Claude (saída JSON validada) → `api.record_ai_result` (resposta ou handoff) |
| IR-06 | A cada 30 s | `api.heartbeat` (sinal de vida do n8n) + `api.claim_alerts` → Telegram → `api.mark_alert_sent` |
| IR-08 | A cada 5 min | API da GGCheckout (pagos nas últimas 2 h, só id/status) → `api.reconcile_gg_batch` |

Aposentados em 05/10/2026: **IR-03** e a parte de banco do **IR-07** rodam no `pg_cron` (0008); **IR-01/IR-02** viram Edge Function; **IR-04** (envio) e o health check da instância voltam quando o provedor de WhatsApp for escolhido.

### Credenciais no n8n (criar com estes nomes; nenhum valor fica em arquivo)
| Nome | Tipo | Conteúdo |
|---|---|---|
| INFORUAN Supabase (n8n_engine) | Postgres | host `aws-0-us-west-2.pooler.supabase.com`, porta 5432, banco `postgres`, usuário `n8n_engine.bsmuouivezjnfrcnamky`, senha do Keychain, SSL `require` (sem "Ignore SSL issues"; CA do Supabase via `NODE_EXTRA_CA_CERTS`, doc 16) |
| GG API (Authorization Bearer) | Header Auth | nome `Authorization`, valor `Bearer ggck_live_…` (chave gerada só para o n8n) |
| Anthropic INFORUAN | Anthropic API | chave da API |
| Telegram INFORUAN | Telegram API | token do bot |

## Implantação (ordem)
1. **Supabase** (`bsmuouivezjnfrcnamky`): `0001`–`0006` + `seed/0001` **já aplicados em 02/10/2026** (0006 via SQL Editor); `0007` (MCP), `0008` (SQL Editor) e `0009` (MCP) **aplicados em 05/10/2026**; login do `n8n_engine` liberado (doc 16). Falta `seed/0002 (local)`.
2. `settings.internal_test_phones` ← telefones internos da equipe.
3. **n8n**: criar as credenciais → `cp n8n/config.example.json n8n/config.local.json` (preencher, sem segredos; `CRED_IDS` opcional) → `node n8n/build.mjs` → importar `n8n/dist/*.json` (continuam inativos). Procedimento em `docs/17`.
4. **Provedor de WhatsApp**: a decidir (até lá, só o provedor `simulated`).
5. **GGCheckout**: webhook (autorizado) apontando para a Edge Function (Etapa 7) — eventos em `docs/06`.
6. Base de conhecimento aprovada (`docs/07`) → `kb_articles` com `approved_by` e `active=true`.
7. Links públicos dos checkouts em `catalog_checkouts.public_url`.

## Travas de ativação (nada envia até TODAS estarem ok)
| Trava | Onde | Libera com |
|---|---|---|
| Modo só internos | `settings.engine_mode = internal_only` | `select set_engine_mode('inforuan', 'live', '<quem>')` (só com autorização) |
| Workflows inativos | n8n | ativar manualmente cada WF |
| Instância pausada (`not_activated`) | `provider_instances` (`inforuan-sim` hoje) | `select unpause_instance('<instância>', '<quem>')` |
| Régua desligada | `sequences.active=false` | `update sequences set active = true where key = 'recovery_pix'` |
| IA sem base | `kb_articles` sem aprovação | artigos aprovados pelo Ruan |

**Ordem sugerida no teste de ponta a ponta** (quando autorizado): telefones internos → IR-06 → Edge Function (só registrar) → compra de teste no checkout `q0EbnyHD8PgIraUBZTTl` (R$ 5) com telefone interno → conferir tabelas → liberar `inforuan-sim` → liberar a régua → conferir o envio simulado e a parada no pagamento → IR-05.

## Operação
- Liberar handoff: `select release_handoff('inforuan', '+55DDDNUMERO', '<quem>')`
- Reembolso feito fora da GGCheckout: `select register_manual_refund('inforuan', '<id do pagamento>', '<quem>')`
- Ajustar limites: `update provider_instances set rate_per_minute = …, min_gap_seconds = …, daily_cap = … where instance_name = '<instância>'`
- Resultado do holdout: `select * from v_recovery_holdout; select * from v_recovery_lift;`
