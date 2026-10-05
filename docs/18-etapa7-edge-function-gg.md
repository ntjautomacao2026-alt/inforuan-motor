# Etapa 7 — Edge Function `gg-webhook` (entrada da GGCheckout)

> **Status: Fase A CONCLUÍDA em 05/10/2026** (0010 aplicada pelo MCP; código da função no banco idêntico ao do repositório, hash `21f10a77…`; só `service_role` executa; `anon`, `authenticated` e `n8n_engine` não; modo `internal_only`; 0 linhas na inbox, 0 eventos, 0 alertas). **Função ainda NÃO publicada.** Cada fase seguinte só com autorização. **Criar o webhook na GGCheckout é uma fase separada**, a última.

## 1. Desenho

```
GGCheckout ──POST──▶ Edge Function gg-webhook ──RPC (service_role)──▶ public.ingest_gg_webhook (0010) ──▶ webhook_inbox → motor
                      • só POST                                         • modo só internos: cliente real DESCARTADO,
                      • segredo obrigatório                               sem gravar payload nem dado pessoal
                        (Bearer, x-secret ou HMAC)                      • limite por minuto (120, configurável) → 429 + alerta
                      • até 64 KB                                       • deduplicação (evento | id | status)
                      • logs sem corpo nem segredo                      • processa na hora (o pg_cron cobre falhas)
```

| Resposta | Quando | Efeito para a GGCheckout |
|---|---|---|
| 200 | gravado, duplicado ou descartado (só internos) | sucesso |
| 401 | segredo ausente ou errado | nada é lido do corpo, nada vai ao banco |
| 405 / 413 / 400 | método errado / corpo acima de 64 KB / JSON ou payload inválido | nada vai ao banco |
| 429 | acima do limite por minuto | a GGCheckout reenvia (3×) e a reconciliação (IR-08) cobre |
| 500 | banco indisponível | a GGCheckout reenvia |
| 503 | `GG_WEBHOOK_SECRET` não configurado | **falha fechada**: nada entra sem segredo |

**Arquivos:**

| Arquivo | Conteúdo |
|---|---|
| `supabase/functions/gg-webhook/handler.ts` | Lógica HTTP, sem dependências. Comparação de segredo em tempo constante; leitura do corpo com limite real (não confia no `content-length`) |
| `supabase/functions/gg-webhook/index.ts` | Liga a lógica ao runtime: `Deno.serve`, `GG_WEBHOOK_SECRET` e chamada RPC com a chave de serviço do próprio runtime. Publicar com **`verify_jwt = false`**, porque a GGCheckout não envia JWT do Supabase; a autenticação é o segredo |
| `supabase/migrations/0010_ingestao_gg.sql` | `ingest_gg_webhook`, ajuste `gg_webhook_rate_per_minute = 120` e índice. Só `service_role` executa |
| `ops/gerar-segredo-gg-webhook.mjs` | Segredo de 48 caracteres gerado no Mac, guardado só no Keychain (`inforuan-gg-webhook-secret`), nunca exibido. `--copiar` põe na área de transferência para colar |
| `ops/testar-gg-webhook.mjs` | Teste da função publicada **sem dado pessoal**: pedido fictício de "cliente real", que no modo só internos é autenticado e descartado |

**Esquema de eventos:** aceita `pix.*`, `card.*` e `payment.*`, porque as fontes da GGCheckout divergem (doc `02`). Os nomes exatos aparecem na tela de criação do webhook, na Fase E.

## 2. Testes locais (45/45; 8 novos)

- **HTTP:** método errado, segredo ausente ou curto, 6 variações de autenticação errada → **nenhuma chamada ao banco**.
- **Autenticação aceita:** Bearer, `x-secret` e HMAC (inclusive hexadecimal maiúsculo). Só cabeçalhos permitidos são repassados (`content-type`, `user-agent`, `x-request-id`, `x-ggcheckout-event`); cookie, chave de API e o segredo nunca.
- **Tamanho:** 413 pelo tamanho declarado e pelo tamanho real, mesmo com `content-length` falso. JSON inválido ou array → 400. Banco fora → 500.
- **Logs:** nunca contêm corpo, nome, e-mail, telefone ou segredo.
- **Banco real (PGlite), modo só internos:**
  - cliente real → 200 descartado, com 0 linhas na inbox e 0 contatos; fica só o evento `gg.ignored_internal_only` com tipo e checkout;
  - checkout de teste e telefone interno → gravados e processados na hora; régua só para o contato interno.
- **Repetição e pagamento:** a mesma notificação 3 vezes gera 1 linha. O pagamento processa na hora e cancela a régua. Em modo `live`, o cliente real entra.
- **Limite:** com 3/min, as requisições 4 e 5 recebem 429, com **1** alerta crítico. Payload sem id → 400.
- **Permissões:** `n8n_engine` não executa `ingest_gg_webhook`.

## 3. Execução proposta (cada fase com autorização)

| Fase | Quem | O quê |
|---|---|---|
| A | eu (MCP) | Aplicar a **0010** (só cria a função de entrada; nada recebe tráfego ainda) |
| B | você | `node ops/gerar-segredo-gg-webhook.mjs` → no Supabase, **Edge Functions → Secrets → Add**: nome `GG_WEBHOOK_SECRET`, valor colado (⌘V) → `pbcopy < /dev/null` |
| C | eu | Publicar `gg-webhook` com `verify_jwt = false`. **Caminho 1:** você autoriza incluir `functions` nas *features* do MCP `supabase-inforuan` (configuração local do Claude; hoje são `database,docs,debugging,development`) e reconectar o MCP; eu publico com `deploy_edge_function`. **Caminho 2:** você cria a função no editor do dashboard e cola os dois arquivos |
| D | você + eu | `node ops/testar-gg-webhook.mjs` (só OK/FALHA). Eu confiro no banco: 0 linhas na inbox, 0 contatos, eventos `gg.ignored_internal_only` do teste e logs da função sem dados |
| E | você, no painel da GGCheckout | **Somente com autorização própria** (é conectar tráfego real, mesmo descartado): Configurações → Webhooks → Adicionar. URL `https://bsmuouivezjnfrcnamky.supabase.co/functions/v1/gg-webhook`, segredo colado com `--copiar`, eventos de Pix e cartão. **Mandar print da tela** com os nomes exatos dos eventos |

Na Fase E, com o motor em **só internos**, os eventos de clientes reais chegam, são autenticados e **descartados sem gravar dados pessoais**. Só o checkout de teste e telefones internos entram. Isso prepara o teste ponta a ponta (Etapa 8).

## 4. Reversão

- **Função:** apagar ou despublicar a `gg-webhook` (Edge Functions → função → Delete), ou remover o secret, que a faz responder 503 (falha fechada).
- **Webhook na GGCheckout:** excluir no painel. A reconciliação (IR-08) continua cobrindo pagamentos.
- **0010:** `drop function public.ingest_gg_webhook(jsonb, jsonb, timestamptz);`. O índice e o ajuste são inofensivos.
