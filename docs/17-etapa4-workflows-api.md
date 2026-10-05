# Etapa 4 — workflows do n8n só pela interface `api`

> **Status: PREPARADO NO REPOSITÓRIO. NÃO IMPORTADO.** A execução fica para **depois de 07/10/2026 18:15 UTC**, quando termina a janela de rollback do PG16, junto com a Parte B da Etapa 3 (doc `16`). Cada fase só com autorização.

## 1. O que mudou no repositório

| Antes (importado no staging, inativo) | Agora (`n8n/build.mjs`) |
|---|---|
| Nós HTTP para `…supabase.co/rest/v1/rpc/*` com credencial **`supabaseApi` (service_role)** | Nó **Postgres v2.7** (`executeQuery`) com a credencial **`INFORUAN Supabase (n8n_engine)`**. Só chama funções `api.*`, com **no máximo um parâmetro `$1::jsonb`** e nenhuma expressão dentro do SQL |
| IR-03 Motor tick | **Aposentado**: `engine_tick` no `pg_cron` a cada 30 s (0008) |
| IR-04 Envio WhatsApp (Evolution) | **Fora até escolher o provedor.** Testes usam o provedor `simulated`, dentro do banco (0007) |
| IR-05 Atendimento IA | `api.claim_ai_work` → Claude → `api.record_ai_result` |
| IR-06 Alertas Telegram | `api.claim_alerts` → Telegram → `api.mark_alert_sent`, **mais o sinal de vida `api.heartbeat('n8n')`** no mesmo gatilho |
| IR-07 Saúde e manutenção | **Aposentado**: handoffs e vigia em `engine_housekeeping` no `pg_cron` (0008). O health check da instância volta com o provedor |
| IR-08 Reconciliação | API da GGCheckout → `api.reconcile_gg_batch` (só id, status e data do pagamento) |
| IR-01/IR-02 (contingência) | **Removidos**: a entrada passa a ser a Edge Function (Etapa 7) |

- `n8n/config.example.json`: só nomes de credenciais e ids opcionais (`CRED_IDS`), nenhum segredo.
- O gerador limpa `n8n/dist/` antes de gerar, para não sobrar JSON de workflow aposentado.

### Testes (37/37)

- **Estrutura:** só IR-05, IR-06 e IR-08, todos `active=false`. Nenhuma referência a `supabaseApi`, `service_role`, `rest/v1` ou `supabase.co`. Todo nó Postgres usa a credencial do `n8n_engine` e só chama funções do schema `api`.
- **Execução real:** o SQL **de cada nó** roda no Postgres local **como `n8n_engine`**, com o `$1` montado pela mesma regra do nó Postgres 2.7 (expressão → array → objeto vira JSON). O que foi conferido:
  - reservar a conversa da IA;
  - registrar o resultado da IA: a mensagem fica marcada como respondida e o handoff é aberto;
  - gravar o sinal de vida;
  - reservar e confirmar o alerta, sem expor `workspace_id`;
  - reconciliar em lote: 1 pedido atualizado e 1 inserido.

## 2. Execução proposta (depois de 07/10 18:15 UTC)

### Fase 0 — garantias (eu)
- Backup imediato do banco do n8n (`/backup.sh`) e linha de base dos outros serviços, como na migração do PG17.
- Cópia do compose atual em `/opt/inforuan-staging/migracao-pg17/`.

### Fase 1 — CA do Supabase no n8n (Parte B do doc 16; eu)
A credencial Postgres do n8n **não tem campo para CA**. Ela só tem SSL `require` e "Ignore SSL Issues", que desliga a verificação. Para manter o TLS verificado:

1. Copiar `infra/certs/supabase-prod-ca-2021.crt` para `/opt/inforuan-staging/certs/` (arquivo público, permissão 644).
2. No serviço `n8n` do compose, adicionar:
   - variável `NODE_EXTRA_CA_CERTS: /certs/supabase-prod-ca-2021.crt`;
   - volume `./certs/supabase-prod-ca-2021.crt:/certs/supabase-prod-ca-2021.crt:ro`.

   Só essas duas linhas mudam. O certificado **soma** uma CA à lista; não afrouxa nada.
3. `docker compose -p inforuan-staging up -d n8n`: recria **só** o container do n8n do INFORUAN, com parada de segundos. O runner se reconecta sozinho.
4. Conferir:
   - n8n `healthy`;
   - de dentro do container, a conexão TLS até `aws-0-us-west-2.pooler.supabase.com` é **verificada** (sem senha);
   - limites e redes iguais;
   - outros projetos intactos;
   - workflows ainda inativos.
5. Atualizar `infra/staging/docker-compose.temporary.yml` no repositório para ficar idêntico ao do servidor.

### Fase 2 — credencial Postgres (você, pelo túnel)
Conforme o doc `16`, B2 a B4: tipo Postgres, nome `INFORUAN Supabase (n8n_engine)`, senha copiada do Keychain e **Test connection**. Eu só leio o **id** da credencial no banco do n8n; o id não é segredo.

### Fase 3 — trocar os workflows
1. **Você** arquiva os 4 workflows antigos no editor (⋯ → Archive): IR-03, IR-05, IR-06 e IR-08. Arquivar é reversível.
2. **Eu** gero com `config.local.json` (não versionado): `CRED_IDS.postgres` = id lido na Fase 2 e, se você já tiver, o `TELEGRAM_CHAT_ID`.
3. **Eu** copio os 3 JSON para uma pasta temporária no container, rodo `n8n import:workflow --separate --input=…` e apago a pasta.

### Fase 4 — conferência (eu, só leitura)
- No banco do n8n:
  - 3 workflows novos com `active = false`;
  - os 4 antigos arquivados;
  - os nós Postgres apontando para o id da credencial;
  - 1 credencial (`postgres`);
  - **0 execuções**.
- No Supabase: nenhum sinal de vida `n8n` criado (nada foi executado), 0 alertas novos, modo `internal_only`.

## 3. O que NÃO acontece nesta etapa
- Nenhum workflow é ativado nem executado.
- Nenhuma outra credencial é criada: IA, Telegram e GGCheckout ficam para a Etapa 5.
- Nenhuma mensagem, webhook ou Edge Function.

**Atenção para a Etapa 6:** executar o IR-06 manualmente grava o sinal de vida `n8n`. Se o IR-06 não ficar ativo, o vigia gera um alerta crítico **"n8n sem sinal de vida"** 15 min depois, a cada hora. Nos testes manuais, apagar essa linha no fim ou ativar o IR-06 (com autorização).

## 4. Reversão
- **Workflows:** desarquivar os 4 antigos e arquivar os 3 novos. Nenhum fica ativo em nenhum dos lados.
- **CA:** voltar o compose pela cópia da Fase 0 e rodar `docker compose -p inforuan-staging up -d n8n`.
- **Credencial:** excluir no editor. Opcionalmente, cortar o login com `alter role n8n_engine nologin;` (doc `16`).
