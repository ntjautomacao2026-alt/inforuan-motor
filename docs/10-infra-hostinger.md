# Infraestrutura — n8n self-hosted na Hostinger (proposta para aprovação, rev. 2)

> Decisões vigentes (02/10):
> - Supabase = **banco oficial do motor**.
> - Webhooks externos → **Edge Functions**.
> - n8n self-hosted isolado na Hostinger, com **PostgreSQL próprio no VPS só para o estado interno do n8n**. Sem SQLite em produção. Sem n8n Cloud.
> - Redis previsto mas **desligado**.
> - Sem Leona.
> - Provedor de WhatsApp a decidir.
> - **Supabase continua no plano gratuito por enquanto** (ver §11).
> - Domínio a definir depois. Nada de DNS agora.
>
> Nada foi provisionado.

## Visão geral

```
GGCheckout ──► Edge Function (segredo + validação + limite de taxa) ─┐
Provedor WA ─► Edge Function (segredo + validação + limite de taxa) ─┤
                                                                     ▼
                     Supabase Postgres — DADOS DO MOTOR (fonte da verdade)
                     • regras/filas/estado  • pg_cron: inbox, régua, handoffs, vigia (SQL puro)
                     • schema `api`: ÚNICA interface que o n8n pode chamar
                                     │ pg_net "acorda" o n8n (segredo próprio)
                                     ▼
 Hostinger VPS ── Caddy (TLS) ── n8n (main) ── task runner
                     │              │
                     │              └── PostgreSQL do n8n (estado interno do n8n; nada do motor)
                     │              └── Redis (previsto, DESLIGADO)
                     └─ Cloudflare na frente (Access no painel; regra de limite de taxa)
```

**Separação de bancos:**
- Supabase guarda **os dados do motor**.
- O Postgres do VPS guarda **só o estado do n8n**: workflows, credenciais cifradas e histórico de execuções.
- Nenhum dos dois acessa o outro, a não ser pela interface do item 5.4.

---

## 1. Requisitos mínimos do servidor

| Item | Mínimo | Recomendado |
|---|---|---|
| Plano Hostinger | KVM 1 (1 vCPU, 4 GB RAM, 50 GB NVMe) | **KVM 2 (2 vCPU, 8 GB RAM, 100 GB NVMe)**, folga para o Postgres do n8n e o task runner |
| Sistema | Ubuntu 24.04 LTS (imagem limpa) | idem |
| Datacenter | **Brasil (São Paulo)** | idem |
| Rede | IPv4 fixo | idem |

## 2. Arquitetura dos containers (Docker Compose, versões fixadas)

| Container | Imagem | Exposição | Volume | Papel |
|---|---|---|---|---|
| `caddy` | `caddy:2.x` | 80/443 (só para IPs do Cloudflare) | `caddy_data` | TLS, proxy reverso, cabeçalhos de segurança |
| `n8n` | `n8nio/n8n:<versão estável>` | 5678 só na rede interna | `n8n_data` (binários temporários) | Editor e execuções. Modo regular |
| `n8n-runner` | `n8nio/runners:<mesma versão>` | — | — | Code nodes isolados do processo principal |
| `n8n-postgres` | `postgres:17-alpine` (o 16 só tem suporte de compatibilidade no n8n 2.x; ver doc `14`) | **sem porta publicada** (rede interna) | `n8n_pg_data` | **Estado interno do n8n**. Usuário, senha e banco exclusivos (`n8n_inforuan`) |
| `redis` | `redis:7-alpine` | — | — | **Previsto e desligado** (perfil `queue` do compose). Só liga com queue mode ou necessidade comprovada |

- Rede Docker interna isolada. Só o Caddy publica portas.
- `restart: unless-stopped`, *healthchecks*, logs com rotação (10 MB × 5).
- n8n: `DB_TYPE=postgresdb` apontando para `n8n-postgres`, `N8N_ENCRYPTION_KEY` exclusiva, `GENERIC_TIMEZONE=America/Sao_Paulo`, `EXECUTIONS_DATA_SAVE_ON_SUCCESS=none`, `EXECUTIONS_DATA_PRUNE=true`, `EXECUTIONS_DATA_MAX_AGE=168`, `N8N_DIAGNOSTICS_ENABLED=false`, `N8N_BLOCK_ENV_ACCESS_IN_NODE=true`, `N8N_COMMUNITY_PACKAGES_ENABLED=false`, `N8N_PUBLIC_API_DISABLED=true`, `N8N_SECURE_COOKIE=true`, `N8N_PROXY_HOPS=1`.
- `infra/docker-compose.yml`, `Caddyfile` e `.env.example` (para a **VPS definitiva**, ainda não criados) ficam no repositório. O `.env` real nunca.
- O staging **temporário** usa outro arquivo: `infra/staging/docker-compose.temporary.yml` (ver docs `12` e `13`).

## 3. Domínio e SSL (adiado)

- Domínio da ntj a definir. **Nada de registro nem DNS agora.**
- Quando definido: DNS no Cloudflare com proxy, TLS **Full (strict)** com *Origin Certificate* no Caddy, HSTS.
- Até lá, o VPS pode ser montado e testado sem expor o painel. Acesso por **túnel SSH** (`ssh -L 5678:localhost:5678`), sem porta pública.

## 4. Persistência e backups

| O quê | Onde | Backup |
|---|---|---|
| Dados do motor | Supabase | Plano gratuito **não tem backup automático** → **dump lógico diário** feito pelo VPS (`pg_dump` do schema `public`), **cifrado** (age/GPG), em armazenamento externo (R2/B2), com retenção de 14 dias. Ver §11 |
| Estado do n8n | Postgres do VPS (`n8n_pg_data`) | `pg_dump` diário cifrado no armazenamento externo (14 dias) + `n8n export` de workflows e credenciais **cifradas** |
| Definição dos workflows | GitHub `inforuan-motor` | Versionado |
| `.env` (senha do Postgres do n8n, `N8N_ENCRYPTION_KEY`, segredos) | Gerenciador de senhas da ntj | A cada alteração |
| VPS inteiro | Hostinger | Backup semanal + **snapshot antes de toda atualização** |

⚠️ A `N8N_ENCRYPTION_KEY` e a senha do Postgres do n8n são **exclusivas do INFORUAN** e vão para o gerenciador de senhas **antes** do primeiro uso.

## 5. Segurança

### 5.1 Painel do n8n (humanos)
- **Cloudflare Access** (e-mail da ntj com código) na frente do editor, mais conta *owner* com **MFA**, sem cadastro aberto e API pública desligada.
- Até o domínio existir: painel **sem exposição pública**, só por túnel SSH.

### 5.2 Endpoints chamados por máquinas (sem login humano)
| Chamada | Proteção |
|---|---|
| Supabase → n8n ("acordar") | Caminho próprio `/webhook/wake/<id>` **liberado no Access**, mais **cabeçalho secreto exclusivo** (credencial Header Auth do n8n). Alternativa: **Cloudflare Service Token** (`CF-Access-Client-Id/Secret` enviados pelo `pg_net`) |
| Claude/MCP → n8n | **Service Token** do Cloudflare Access + token do MCP do n8n |
| n8n → Supabase | Ver 5.4 (interface restrita) |

### 5.3 Webhooks externos (nenhum aberto sem autenticação, validação e limite)
| Camada | Regra |
|---|---|
| Edge Function | 1) segredo obrigatório (comparação em tempo constante), 401 sem gravar nada. 2) tamanho máximo do corpo (64 KB) e JSON válido. 3) validação mínima do formato (evento conhecido, id presente). 4) **limite de taxa por origem**: contador por minuto no banco, 429 acima do teto, com alerta. 5) grava bruto, responde 200 e processa em etapa separada |
| n8n `/webhook/*` | Só aceita o "acordar" (5.2). **Regra de limite de taxa do Cloudflare** no caminho. Tudo o mais do n8n fica atrás do Access |
| VPS | UFW: 80/443 só de IPs do Cloudflare; SSH só por chave, sem root, `fail2ban`, patches automáticos |

### 5.4 O n8n não lê as tabelas do motor
- O n8n **não recebe a `service_role`**. Ele usa um usuário Postgres próprio no Supabase (`n8n_engine`, login e senha exclusivos), que **só tem permissão de EXECUTAR funções do schema `api`**: `claim_outbound`, `mark_outbound_result`, `claim_ai_work`, `record_ai_result`, `claim_alerts`, `mark_alert_sent`, `reconcile_gg_batch`, `set_instance_state`, `cancel_outbound`, `heartbeat`. **Nenhum SELECT, INSERT ou UPDATE direto** em tabela.
- As funções do schema `api` são *wrappers* `SECURITY DEFINER` com `search_path` fixo. Fica para a migração `0006` (proposta, não aplicada).

## 6. Política de atualização

| Componente | Regra |
|---|---|
| n8n + runner | Versão fixada. Revisão semanal das notas de versão. Atualização **mensal** entre 02h e 05h. **Segurança em até 72 h** |
| Postgres do n8n | Só *minor* automáticas no ciclo mensal. *Major* com dump/restore planejado |
| Caddy, Redis | Versões fixadas, junto com o n8n |
| Sistema operacional | Patches de segurança automáticos. Reinício mensal |
| Antes / depois | Snapshot + dump do Postgres do n8n → checklist rápido (login, execução de teste, alerta no Telegram, "acordar") |
| Reversão | Tag anterior + restaurar o dump pré-atualização |

## 7. Monitoramento

| Sinal | Como | Alerta |
|---|---|---|
| n8n fora do ar | Monitor externo em `/healthz` (quando houver domínio). Antes disso, o *heartbeat* abaixo | Telegram + e-mail |
| n8n vivo mas parado | n8n chama `api.heartbeat()` a cada 5 min. O `pg_cron` detecta atraso e **avisa o Telegram direto pelo `pg_net`** | Telegram |
| Execução com erro | *Error workflow* do n8n | Telegram |
| Disco, memória, Postgres do n8n | Script cron no VPS (disco > 80%, memória > 90%, Postgres sem responder) | Telegram |
| Negócio | Vigia do motor (sem webhook da GGCheckout, fila parada, provedor caído) | Telegram |
| Supabase | Tamanho do banco vs. 500 MB, uso de Edge Functions e egress (semanal) | Telegram ao passar de 60% |

## 8. Estimativa de custo mensal (confirmar no checkout)

| Item | Valor |
|---|---|
| Hostinger KVM 2 (promoção; renovação mais cara) | R$ 45–70 |
| Supabase **Free** | R$ 0 |
| Cloudflare (DNS/Access/limite de taxa), monitor, Telegram | R$ 0 |
| Armazenamento de backup externo (R2/B2, poucos GB) | R$ 0–5 |
| **Subtotal de infraestrutura** | **~R$ 45–75** |
| IA (variável, ~100 respostas/dia) | ~R$ 150–450 |
| Domínio (quando definido) | ~R$ 3,50 |
| Provedor de WhatsApp | a definir |
| *Futuro:* Supabase Pro (quando um gatilho de §11 disparar) | +~R$ 140 |

## 9. Procedimento de recuperação

| Cenário | Efeito | Recuperação | Tempo / perda |
|---|---|---|---|
| VPS cai | Webhooks e regras continuam no Supabase. Envios e IA esperam na fila | VPS novo → `git clone` → `.env` do gerenciador de senhas → restaurar o dump do Postgres do n8n → `docker compose up -d` | ~1–2 h · motor sem perda · n8n até 24 h (último dump) |
| Postgres do n8n corrompido | n8n não sobe | Restaurar o dump diário (ou reimportar workflows do Git + recriar credenciais) | ~30–60 min |
| Atualização ruim | n8n com erro | Tag anterior + dump pré-atualização | ~30 min |
| Supabase pausado por inatividade | Webhooks falham | *Heartbeat* evita isso. Se ocorrer: "Resume project" no painel + reconciliação com a API da GGCheckout | minutos |
| Perda de dados no Supabase (plano gratuito) | — | Restaurar o **dump diário próprio** num projeto novo + reconciliação | até 24 h de perda |
| Vazamento de credencial | — | Rotacionar: senha do `n8n_engine`, chaves do Supabase, senha do Postgres do n8n, `N8N_ENCRYPTION_KEY`*, GGCheckout, Anthropic, Telegram, provedor, segredos dos webhooks | imediato |

\* Rotacionar a chave de criptografia exige recadastrar as credenciais do n8n.

**Teste de recuperação trimestral**, a partir do repositório e dos dumps.

## 10. Onde ficam os dados

| Local | Dados | Natureza |
|---|---|---|
| **Supabase** | Tudo do motor: contatos, pedidos, eventos, webhooks brutos, mensagens, filas, handoffs, base de conhecimento, execuções da IA, alertas, experimentos · segredos das Edge Functions | Persistente. Fonte da verdade |
| **VPS — Postgres do n8n** | Workflows, credenciais **cifradas**, metadados de execução (7 dias; sucesso não salvo) | Persistente, com backup próprio cifrado |
| **VPS — temporário** | Execuções em andamento (memória) · logs (7 dias; podem conter trechos de erro) · binários temporários · certificados · `.env` | Descartável |
| **Armazenamento externo** | Dumps **cifrados** (motor + n8n), 14 dias | Backup |
| **GitHub** | Código, migrações, workflows, infraestrutura como código | Sem segredos |
| **Gerenciador de senhas da ntj** | Todos os segredos | — |

## 11. Supabase Free atende o MVP?

Limites oficiais consultados em 02/10/2026:

| Limite (Free) | Valor | Uso estimado do MVP | Situação |
|---|---|---|---|
| Tamanho do banco | **500 MB**; acima disso o banco fica **somente leitura** | Hoje 12 MB. Crescimento de ~80–170 MB/mês sem limpeza (3,5–7,7 mil pedidos/mês; o JSON bruto dos webhooks é o maior item) | ⚠️ Atende **com política de retenção** (§11.1). Sem ela, estoura em 3–6 meses |
| Edge Functions | **500 mil invocações/mês**; 2 s de CPU por chamada; 150 s de duração | ~30–40 mil/mês (GGCheckout + eventos do WhatsApp) | ✅ ~8% da cota |
| Banda (egress) | **5 GB não-cache** + 5 GB cache | n8n chamando funções + leituras: centenas de MB/mês | ✅ |
| Pausa por inatividade | Pausa se houver pouca atividade em 7 dias | Webhooks frequentes + *heartbeat* a cada 5 min | ✅ com *heartbeat* |
| **Backup** | **Nenhum automático** | — | ❌ → **dump diário próprio cifrado** (§4) |
| PITR | Indisponível | — | Aceitável no MVP |
| Compute | Nano (compartilhado) | Carga baixa (dezenas de operações/min) | ✅ |
| Logs | Retenção curta | Rastro principal fica nas próprias tabelas | ✅ |

### 11.1 Condições para seguir no Free
1. **Retenção:** apagar `webhook_inbox.payload` processado e `orders.raw_last` após 30 dias, e `message_status_events.raw` após 30 dias. Isso entra na migração `0006`, proposta e não aplicada.
2. **Dump diário cifrado** fora do Supabase, a partir do VPS.
3. ***Heartbeat*** a cada 5 min (anti-pausa e monitoramento ao mesmo tempo).

### 11.2 Quando migrar para o Pro (gatilhos)
- Banco acima de **300 MB** mesmo com retenção.
- Necessidade de backup gerenciado ou PITR (por exemplo, volume e receita dependendo do motor).
- Edge Functions acima de 60% da cota.
- Qualquer pausa ou modo somente leitura em produção.
