# Etapa 2 — modo "só internos", envio simulado e `pg_cron`

> **Status: APLICADO em 05/10/2026, com autorização.** 0007 pelo MCP; 0008 pelo SQL Editor (o MCP recusou). Resultado na seção 9.
> Escopo: **somente** o Supabase do INFORUAN (projeto `bsmuouivezjnfrcnamky`). A VPS e o n8n não mudam.

## 1. Estado antes (leitura de 05/10/2026)

| Item | Valor |
|---|---|
| Postgres | 17.11 |
| Migrações aplicadas | 0001 a 0006 + seed |
| Dados | 0 pedidos, 0 contatos, 0 mensagens, 0 alertas, 0 matrículas |
| Régua `recovery_pix` | **inativa** |
| Instâncias de envio | nenhuma |
| `internal_test_phones` | lista vazia |
| `pg_cron` / `pg_net` | não instalados (`pg_cron` 1.6.4 disponível) |
| Funções do schema `api` | 10 |

## 2. O que muda

### 0007 — `supabase/migrations/0007_modo_interno.sql`

1. **Novo ajuste `engine_mode` = `internal_only`.** Qualquer valor diferente de `live` vale como "só internos", inclusive ajuste apagado ou digitado errado.
2. **Régua:** fora do modo `live`, só os contatos internos (os telefones em `internal_test_phones`) são matriculados. Um cliente real não é matriculado nem sorteado no grupo de controle, então não contamina a medição.
3. **Fila:** fora do modo `live`, **nenhuma mensagem é enfileirada** para quem não é interno, e isso vale também para o pós-venda. A tentativa fica registrada como evento `outbound.suppressed`, sem texto da mensagem.
4. **Envio (segunda barreira):** fora do modo `live`, uma mensagem de um não interno que já esteja na fila é **cancelada** no momento do envio (`internal_only`).
5. **Provedor `simulated`:** instância `inforuan-sim` que "envia" sem sair do banco. Ela marca a mensagem como enviada com o id `sim:…`. **Nasce pausada** e **só pega mensagens de contatos internos**, mesmo no modo `live`.
6. **`set_engine_mode(...)`:** troca de modo só pelo operador, com nome obrigatório. Gera um alerta crítico ao ligar o `live`. O n8n não pode chamar essa função.
7. **`engine_tick`:** faz o que o IR-03 fazia, em SQL puro. Processa a inbox, passa as ações vencidas da régua para a fila, destrava envios presos e roda o envio simulado (só se a `inforuan-sim` estiver liberada). Também registra um sinal de vida `db_tick`.
8. **`engine_housekeeping`:** a parte de banco do IR-07: expira handoffs, promove a fila das 9h e roda o vigia.
9. **Vigia:** ignora a instância simulada no alerta de "health check parado".
10. **Permissões:** as funções novas não são executáveis por `anon`, `authenticated` nem `n8n_engine`. O schema `api` continua com as mesmas 10 funções.

### 0008 — `supabase/migrations/0008_pg_cron.sql`

Instala o `pg_cron`. O `pg_net` **não** é instalado. São criados 3 agendamentos (horários em UTC):

| Job | Frequência | Faz |
|---|---|---|
| `inforuan-tick` | a cada 30 s | `engine_tick('inforuan')` |
| `inforuan-housekeeping` | a cada 5 min | `engine_housekeeping('inforuan')` |
| `inforuan-maintenance` | 06:30 UTC (03:30 em São Paulo) | retenção de 30 dias + limpeza do histórico do próprio cron (7 dias) |

## 3. Por que isso não envia nada

Ao mesmo tempo, depois da aplicação:

- o modo é `internal_only`;
- a lista de internos está **vazia**;
- a régua está **inativa**;
- a única instância é a simulada, e ela está **pausada**;
- não há webhook, Edge Function ou `pg_net`, e nenhuma credencial está cadastrada no n8n.

Com isso, os jobs rodam sobre tabelas vazias. Nenhum caminho sai do banco: o `pg_cron` não faz chamadas de rede.

## 4. Testes locais (PGlite)

**34 de 34 passando**: os 28 anteriores (rodando em modo `live` para manter o comportamento original coberto) e 6 novos.

- No modo só internos, o cliente real não é matriculado nem sorteado, e o interno recebe os 4 passos.
- No modo só internos, o pagamento de um cliente real não enfileira pós-venda e fica registrado como suprimido.
- Um modo inválido vale como só internos. Ao voltar do `live`, os não internos que estavam na fila são cancelados. Modo inválido ou sem operador é recusado, e ligar o `live` gera um alerta crítico.
- A instância simulada nasce pausada, nunca pega cliente real e marca o envio como `sim:`. Usá-la com uma instância que não é simulada dá erro.
- `engine_tick` ponta a ponta: Pix interno, régua, envio simulado, pagamento, régua cancelada e pós-venda simulado. O vigia não alerta pela instância simulada.
- `n8n_engine` não executa `engine_tick`, `simulate_outbound`, `set_engine_mode` nem `engine_housekeeping`.

O `pg_cron` (0008) não existe no PGlite. Ele é conferido no Supabase depois da aplicação.

## 5. Como aplicar

1. **Tentativa 1:** pelo MCP do Supabase (`apply_migration`), com 0007 e depois 0008.
2. **Se o MCP recusar** (como aconteceu na 0006): você cola o arquivo de `supabase/manual/` no SQL Editor e clica em Run. Ele roda numa única transação (tudo ou nada) e registra a migração no histórico. Foi o que aconteceu com a 0008: `supabase/manual/0008_aplicar_no_sql_editor.sql`.

## 6. Conferência depois da aplicação (feita por mim, só leitura)

1. O histórico de migrações mostra `0007_modo_interno` e `0008_pg_cron`.
2. `engine_mode = internal_only`; a `inforuan-sim` está pausada; a régua continua inativa; `internal_test_phones` continua vazio.
3. As funções no banco são idênticas às do repositório (comparação de hash do código).
4. `cron.job`: 3 jobs `inforuan-*` ativos.
5. Depois de cerca de 1 minuto, `cron.job_run_details` mostra execuções do `inforuan-tick` com `succeeded` e um sinal de vida `db_tick` recente.
6. Os resultados do tick não processaram nada (inbox vazia) e não há nenhum alerta novo.
7. `n8n_engine` sem `EXECUTE` nas funções novas e o schema `api` com 10 funções.
8. Auditoria do Supabase (segurança e desempenho) sem itens novos de erro ou aviso.

## 7. Reversão

`supabase/manual/0007_0008_reverter.sql`:

- **Passo 1 (imediato):** `cron.unschedule` dos 3 jobs. Isso para toda a automação.
- **Passo 2 (completo, opcional):** reaplica 0002, 0004 e 0006 (definições originais) e remove as funções novas, a instância simulada, o ajuste `engine_mode`, a restrição nova, a extensão e o registro no histórico.

## 8. O que continua fora desta etapa

- Nenhum telefone interno é cadastrado. Isso será feito por você no SQL Editor, na etapa de testes, sem versionar.
- A régua não é ativada, a instância simulada não é liberada e o modo `live` não é ligado.
- `pg_net`, Edge Function, webhook da GGCheckout, login do `n8n_engine` e credenciais no n8n não fazem parte desta etapa.
- Os workflows do n8n não são alterados. O IR-03 e o IR-07 ficam obsoletos e serão retirados na Etapa 4.

## 9. Resultado da aplicação (05/10/2026)

| Verificação | Resultado |
|---|---|
| Histórico | `0007_modo_interno` (20261005182659, MCP) e `0008_pg_cron` (20261005190100, SQL Editor) |
| Código das funções | **9 de 9 idênticas** ao repositório (hash do código no banco × PGlite) |
| Estado | `engine_mode = internal_only`; `inforuan-sim` pausada; régua inativa; `internal_test_phones` vazio |
| `pg_cron` | 1.6.4 em `pg_catalog`; 3 jobs `inforuan-*` ativos, dono `postgres`. `pg_net` não instalado |
| Execuções | `inforuan-housekeeping` (18:30:00 UTC) e `inforuan-tick` (a partir de 18:30:13 UTC, ~13 ms) com `succeeded`; sinal de vida `db_tick` gravado |
| Efeitos | 0 alertas, 0 eventos, 0 mensagens, 0 matrículas |
| Permissões | `n8n_engine` sem `EXECUTE` nas funções novas e sem acesso ao schema `cron`; `anon` sem `EXECUTE` em `public`; `search_path` fixo em todas as funções; `api` com 10 funções |
| Auditoria do Supabase | Só avisos informativos já conhecidos (RLS sem policies, de propósito; índices ainda sem uso). Nenhum erro ou aviso |
| Testes locais | 34/34 |
