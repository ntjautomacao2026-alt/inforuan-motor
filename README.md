# INFORUAN — Motor de monetização (fase 1: recuperação de Pix, pós-venda e atendimento)

Núcleo **Supabase (estado e regras críticas) + n8n (execução/integrações)**. Transporte inicial: **Evolution via QR**, atrás de uma camada única de envio. O Leona fica só na coexistência oficial.
Arquitetura e decisões em [`docs/`](docs/). **Nada está ativo.**

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
| `supabase/seed/0001_config.sql` | Config inicial segura: **régua inativa, nenhuma instância de envio** (provedor a decidir), holdout 10%, templates-rascunho |
| `supabase/seed/0002_catalog_links.local.sql` | Links de entrega atuais (não versionar) + links públicos dos checkouts (a preencher) |
| `n8n/build.mjs` → `n8n/dist/*.json` | 8 workflows importáveis, todos `active=false` |
| `prompts/atendimento-system.md` | Prompt do atendimento (IA limitada à base) |
| `tests/engine.test.mjs` | 25 testes das regras críticas no Postgres real (PGlite) |
| `ops/evolution-checklist.md` | Webhook global, instância, coexistência, migração de servidor |

## Testes
```bash
npm install && npm test
```

## Workflows n8n
| WF | Gatilho | Função |
|---|---|---|
| IR-01 | Webhook GGCheckout (Header Auth) | Valida segredo → grava bruto (dedupe) → **responde 200** → processa em etapa separada |
| IR-02 | Webhook Evolution | Filtra instância → grava bruto sem token → 200 → processa |
| IR-03 | A cada 20 s | Inbox pendente, régua → fila, destrava envios incertos |
| IR-04 | A cada 10 s | Reserva 1 mensagem (limites/pausa/guard/TTL no banco) → se recuperação, confere pagamento na GGCheckout → Evolution → registra resultado |
| IR-05 | A cada 10 s | Conversas prontas (debounce 20 s) → Claude (saída JSON validada) → resposta ou handoff |
| IR-06 | A cada 30 s | Alertas → Telegram |
| IR-07 | A cada 60 s | Estado da instância (pausa automática), handoffs (expiração + fila das 9h), vigia |
| IR-08 | A cada 5 min | Reconciliação de pagamentos pela API da GGCheckout |

### Credenciais no n8n (criar com estes nomes; nenhum valor fica em arquivo)
| Nome | Tipo | Conteúdo |
|---|---|---|
| Supabase INFORUAN | Supabase API | URL + **service_role key** |
| GG Webhook Secret (x-secret) | Header Auth | nome `x-secret`, valor = segredo do webhook |
| GG API (Authorization Bearer) | Header Auth | nome `Authorization`, valor `Bearer ggck_live_…` (chave gerada só para o n8n) |
| Evolution INFORUAN (apikey da instância) | Header Auth | nome `apikey`, valor = **token da instância** (nunca a chave global) |
| Anthropic INFORUAN | Anthropic API | chave da API |
| Telegram INFORUAN | Telegram API | token do bot |

## Implantação (ordem)
1. **Supabase** (`bsmuouivezjnfrcnamky`): `0001`–`0006` + `seed/0001` **já aplicados em 02/10/2026** (0006 via SQL Editor). Falta `seed/0002 (local)`.
2. `settings.internal_test_phones` ← telefones internos da equipe.
3. **n8n novo**: criar as credenciais → `cp n8n/config.example.json n8n/config.local.json` (preencher, sem segredos) → `node n8n/build.mjs` → importar `n8n/dist/*.json` (continuam inativos).
4. **Evolution**: seguir `ops/evolution-checklist.md` (webhook global primeiro).
5. **GGCheckout**: criar o webhook (autorizado) apontando para IR-01 — eventos em `docs/06`.
6. Base de conhecimento aprovada (`docs/07`) → `kb_articles` com `approved_by` e `active=true`.
7. Links públicos dos checkouts em `catalog_checkouts.public_url`.

## Travas de ativação (nada envia até TODAS estarem ok)
| Trava | Onde | Libera com |
|---|---|---|
| Workflows inativos | n8n | ativar manualmente cada WF |
| Instância pausada (`not_activated`) | `provider_instances` | `select unpause_instance('inforuan-01', '<quem>')` |
| Régua desligada | `sequences.active=false` | `update sequences set active = true where key = 'recovery_pix'` |
| IA sem base | `kb_articles` sem aprovação | artigos aprovados pelo Ruan |

**Ordem sugerida no teste de ponta a ponta** (quando autorizado): IR-06/IR-07 → IR-01/IR-02/IR-03 (só registrar) → compra de teste no checkout `q0EbnyHD8PgIraUBZTTl` (R$ 5) com telefone interno → conferir tabelas → liberar a instância → liberar a régua → IR-04 → IR-05.

## Operação
- Liberar handoff: `select release_handoff('inforuan', '+55DDDNUMERO', '<quem>')`
- Reembolso feito fora da GGCheckout: `select register_manual_refund('inforuan', '<id do pagamento>', '<quem>')`
- Ajustar limites: `update provider_instances set rate_per_minute = …, min_gap_seconds = …, daily_cap = … where instance_name = 'inforuan-01'`
- Resultado do holdout: `select * from v_recovery_holdout; select * from v_recovery_lift;`
