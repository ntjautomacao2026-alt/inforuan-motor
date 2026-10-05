# Etapa 3 — login do `n8n_engine` e conexão do n8n ao Supabase

> **Status: Parte A CONCLUÍDA em 05/10/2026** (resultado na seção 6). **Parte B pendente** (depois de 07/10/2026 18:15 UTC, com autorização).
> Princípio: **a senha em texto puro nunca passa pelo chat, por arquivo versionado nem pelo Supabase.** Ela nasce no seu Mac, fica no Keychain e só é digitada (colada) por você no n8n.

## 1. Estado antes (leitura de 05/10/2026)

| Item | Valor |
|---|---|
| `n8n_engine` | **sem login**, sem senha, `NOINHERIT`, limite de 10 conexões, não é membro de nenhum grupo, sem superusuário, `CREATEROLE`, `CREATEDB` ou `BYPASSRLS` |
| Schemas que alcança | `api`, `public`, `pg_catalog`, `information_schema` (sem `CREATE` em nenhum) |
| Em `public` | nenhuma tabela, visão ou função |
| Em `api` | as 10 funções da interface |
| Concessões padrão do Supabase (`cron`, `auth`, `storage`, `extensions`, `realtime`) | dadas ao público, mas **inúteis** sem acesso ao schema. O teste da Parte A confirma conectado de verdade |
| Cifra de senha do banco | `scram-sha-256` |

## 2. Parte A — liberar o login (somente Supabase + Mac)

| # | Quem | O quê |
|---|---|---|
| A1 | eu (MCP) | Aplicar **0009** (`supabase/migrations/0009_n8n_engine_limites.sql`): limite de 10 conexões e timeouts de sessão (consulta 15 s, espera por lock 5 s, transação parada 60 s). **Não** libera login |
| A2 | você, no Terminal do Mac | `node ops/gerar-senha-n8n-engine.mjs` |
| A3 | você, no SQL Editor | Colar (⌘V) e clicar em Run. Deve voltar `rolcanlogin = true` e `tem_senha = true` |
| A4 | você, no dashboard | **Connect → Session pooler**: me dizer só o **host** (ex.: `aws-0-sa-east-1.pooler.supabase.com`). Não é segredo |
| A5 | você, no Terminal | `node ops/testar-n8n-engine.mjs <host>`. Imprime só OK/FALHA |
| A6 | eu (só leitura) | Conferir o sinal de vida `teste_conexao`, que não ficou nenhuma sessão aberta e que a auditoria do Supabase continua limpa. Depois apago a linha `teste_conexao` |

**O que o gerador (A2) faz:**

- cria uma senha aleatória de 40 caracteres e **não a exibe**;
- guarda a senha só no Keychain (serviço `inforuan-supabase-n8n_engine`);
- recusa sobrescrever uma senha existente, a não ser com `--rotacionar`;
- copia para a área de transferência o SQL `alter role n8n_engine with login password 'SCRAM-SHA-256$…'`. A senha já vai cifrada, no mesmo formato que o Postgres grava; o algoritmo foi conferido contra o próprio Postgres.

**O que o teste (A5) verifica:**

- conexão TLS com o certificado verificado e sessão criptografada;
- o usuário da sessão é `n8n_engine` e os limites da 0009 estão ativos;
- `api.heartbeat` funciona;
- **bloqueios** (todos precisam dar "permission denied"):
  - `public.contacts` e `public.settings`;
  - `public.engine_tick` e `public.set_engine_mode`;
  - `cron.job`, `auth.users`, `storage.objects` e `extensions.pg_stat_statements`;
  - criar tabela ou schema.

Se o certificado não for reconhecido pela cadeia padrão, o teste **avisa como FALHA**. Ele só continua sem verificação para concluir os testes de permissão. Antes da Parte B, decidimos como tratar isso, por exemplo usando o certificado CA do Supabase.

## 3. Parte B — credencial no n8n (somente depois de 07/10/2026 18:15 UTC)

Fica para depois porque, até essa data, o volume antigo do PostgreSQL 16 do n8n ainda é a garantia de volta. Uma credencial cadastrada agora se perderia num eventual rollback.

| # | Quem | O quê |
|---|---|---|
| B1 | eu | Abrir o túnel SSH e a página do n8n |
| B2 | você | Credenciais → nova **Postgres**: nome `INFORUAN Supabase (n8n_engine)`; host `aws-0-us-west-2.pooler.supabase.com`; porta `5432`; banco `postgres`; usuário `n8n_engine.bsmuouivezjnfrcnamky`; SSL `require`, **sem** "Ignore SSL issues"; máximo de conexões baixo (até 5). A verificação do certificado exige a CA do Supabase (seção 6): se a credencial do n8n não tiver campo para CA, a alternativa é montar `infra/certs/supabase-prod-ca-2021.crt` somente leitura no container e definir `NODE_EXTRA_CA_CERTS`. Isso muda o compose e reinicia só o n8n do INFORUAN, então pede autorização própria |
| B3 | você | Senha: no Terminal, `security find-generic-password -s inforuan-supabase-n8n_engine -a n8n_engine -w \| pbcopy`. Colar no campo e, logo depois, limpar a área de transferência com `pbcopy < /dev/null` |
| B4 | você | **Test connection** no n8n (testa também a rede da VPS até o Supabase) e salvar |
| B5 | eu (só leitura) | No banco do n8n: 1 credencial do tipo `postgres`, os workflows continuam inativos e sem uso dessa credencial. No Supabase: sessões do `n8n_engine` só durante o teste |

Nada é ativado e nenhum workflow é alterado. A reescrita dos workflows para `api.*` é a Etapa 4.

## 4. Riscos e mitigação

| Risco | Mitigação |
|---|---|
| O pooler do Supabase é público: qualquer um pode tentar logar como `n8n_engine` | Senha de 40 caracteres aleatórios, cifra SCRAM e bloqueio de tentativas repetidas pelo próprio pooler. Mesmo com a senha, o `n8n_engine` só chama as 10 funções da `api`: não lê dados, não troca o modo do motor e não mexe na régua |
| Senha vazar | Ela existe só no Keychain e na credencial cifrada do n8n. Corte imediato com `alter role n8n_engine nologin;`. Troca com `--rotacionar` + colar o SQL de novo + atualizar no n8n |
| Consulta travada ou esquecida segurando o banco | Timeouts da 0009 e limite de 10 conexões |
| Histórico do SQL Editor | Contém só a senha cifrada, nunca o texto puro. Não salvar como snippet |
| Endurecimento extra | Opcional, na VPS definitiva: *Network Restrictions* do Supabase, liberando só os IPs necessários. Vale para todas as conexões ao banco, por isso fica para depois |

## 5. Reversão

```sql
alter role n8n_engine nologin;                                                            -- corta novos logins na hora
select pg_terminate_backend(pid) from pg_stat_activity where usename = 'n8n_engine';      -- derruba sessões abertas
```

A 0009 (timeouts) pode ficar, porque não tem efeito sem login. Para remover a senha: `alter role n8n_engine password null;`.

## 6. Resultado da Parte A (05/10/2026)

| Verificação | Resultado |
|---|---|
| 0009 (MCP) | Aplicada. `connection limit 10`, `statement_timeout=15s`, `lock_timeout=5s`, `idle_in_transaction_session_timeout=60s` |
| Senha | Gerada no Mac e guardada só no Keychain (`inforuan-supabase-n8n_engine`). No banco: `rolcanlogin = true`, senha em formato `SCRAM-SHA-256$…`. O texto puro nunca saiu do Mac |
| Host do pooler (modo sessão) | `aws-0-us-west-2.pooler.supabase.com:5432`. O projeto está em us-west-2 (Oregon). Da VPS no Brasil, espera-se ~150–200 ms de rede por chamada. Aceitável no MVP (poucas chamadas; o trabalho pesado roda no `pg_cron`). Reavaliar na VPS definitiva |
| TLS | Mac → pooler em **TLS 1.3** (AES-256-GCM). O certificado `*.pooler.supabase.com` é emitido pela CA própria do Supabase (Intermediate → **Supabase Root 2021 CA**), por isso a cadeia padrão do sistema não o reconhece |
| CA do Supabase | Baixada do dashboard e guardada em `infra/certs/supabase-prod-ca-2021.crt` (pública). SHA-256 `80:70:25:AD…:CA:FA`, **igual** à raiz apresentada pelo pooler. Com ela, verificação completa: `authorized = true` |
| Teste `ops/testar-n8n-engine.mjs` (2ª rodada) | **TUDO OK**: certificado verificado com a CA do Supabase, sessão como `n8n_engine`, limites ativos, `api.heartbeat` funcionando e **10 de 10 bloqueios** (`public.contacts`, `public.settings`, `public.engine_tick`, `public.set_engine_mode`, `cron.job`, `auth.users`, `storage.objects`, `extensions.pg_stat_statements`, criar tabela e criar schema) |
| 1ª rodada | Duas FALHAS sem relação com permissão. (1) Certificado sem a CA do Supabase: resolvido como acima. (2) "Sessão sem SSL": o teste olhava `pg_stat_ssl`, que mede o trecho pooler → banco, interno do Supabase. O teste foi corrigido para medir o TLS do cliente |
| Efeitos no banco | Nenhum objeto criado. 0 alertas, 0 eventos, modo `internal_only`. A única sessão do `n8n_engine` que permanece é a do próprio pooler (Supavisor, `idle`, após `DISCARD ALL`), que ele recicla sozinho |
| Pendência menor | A linha de sinal de vida `teste_conexao` continua em `service_heartbeats`: a remoção pelo MCP foi recusada pela confirmação. É inofensiva (o vigia só olha `n8n`). Pode ser apagada no SQL Editor com `delete from service_heartbeats where service = 'teste_conexao';` |
