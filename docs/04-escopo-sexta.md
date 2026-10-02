# Escopo mínimo seguro — entrega de sexta-feira, 02/10/2026

> Status: **proposta**. Nada implementado. Base aprovada: **Supabase + n8n + Leona (API oficial da Meta)**, com **contas novas e 100% isoladas de outras operações** (Supabase, n8n, Leona e número). Nenhuma conta, credencial, dado ou workflow da outra operação é reutilizado.
> Webhook, checkout de teste e holdout: ver `06-propostas-para-aprovacao.md`. Base de conhecimento: `07-checklist-base-conhecimento.md`.
>
> **Atualização (30/09): transporte = Evolution API via QR** (número novo), com o Leona só para a coexistência oficial. Onde este documento cita "Leona" para envio, handoff ou templates, vale a **camada de envio** de `09-camada-de-envio.md`. Consequências: (1) **não depende de aprovação de template da Meta para sexta**; (2) status de entregue/lido disponíveis; (3) inbox humana = WhatsApp Business no celular; (4) novo item no caminho crítico: **testar a Evolution via QR junto com a coexistência**.
> Princípio: nada de estado importante só dentro de execução ou espera do n8n. Toda espera é uma linha em `scheduled_actions` no Supabase.

## 1. O que entra (obrigatório)

| # | Item | Critério de pronto |
|---|---|---|
| 1 | Recuperação de Pix não pago | Pedido Pix não pago recebe a régua no WhatsApp, com registro de cada envio |
| 2 | Interrupção após pagamento | Pagamento cancela todos os passos pendentes. Guard no envio consulta o status na GGCheckout. **Teste: zero mensagem de cobrança para quem pagou** |
| 3 | Pós-compra com orientação de acesso | Todo pedido pago recebe uma mensagem com o **mesmo link já entregue hoje** e instruções de acesso |
| 4 | IA limitada à base de conhecimento | Responde só o que está na base; fora dela, transfere. Nunca inventa preço, oferta ou prazo |
| 5 | Handoff humano 9h–20h | Dentro do horário: transfere e avisa a equipe. Fora: informa o horário, registra e põe em fila |
| 6 | Registro básico | Tabelas `messages` e `handoffs` com todo envio, resposta, resposta da IA e transferência |

## 2. O que NÃO entra (só planejado ou em rascunho, **não ativado**)
- Separação de conteúdos e pastas, novas ofertas, cross-sell, mudança no upsell atual.
- Checkout abandonado antes do Pix, winback, dashboard completo, UI de administração, Meta Ads.
- Recuperação nativa de WhatsApp da GGCheckout: **continua desligada**.

### Riscos fora do motor que precisam de dono antes de sexta
- **5 clientes** pagaram bumps sem arquivo na pasta (Limpar Nome ×2, Negociar Dívidas ×2, Pix Sem Golpe ×1). Ver `05-matriz-comercial.md`.
- **Checkout "É Golpe ou Não É?" publicado com pasta vazia.** Não usar em teste de ponta a ponta nem receber tráfego até ter conteúdo. O teste real passa a usar outro produto de valor baixo, ou um produto de teste criado para isso.

## 3. Arquitetura da entrega

```
GGCheckout ──webhook (pix.generated / pix.paid / card.paid / pix.expired)──► n8n WF-01 Ingestão
   │                                                                           │ grava bruto + chama RPC
   │                                                                           ▼
   │                                                      Supabase: apply_event()  ← REGRAS CRÍTICAS EM SQL
   │                                                        • upsert contato/pedido • evento append-only
   │                                                        • pix.generated → matricula régua + agenda passos
   │                                                        • paid → CANCELA passos + agenda pós-compra
   │                                                        • holdout 10% (sorteio fixo por contato)
   │
   ├──API (a cada 5 min)──► n8n WF-03 Reconciliação → emite `paid` perdido (webhook falhou)
   │
   └──API check_payment (antes de cada envio de cobrança)──┐
                                                           ▼
n8n WF-02 Dispatcher (cron 1 min) → RPC claim_due_actions() [SKIP LOCKED + guard em SQL]
      → confirma status na GGCheckout → envia via Leona (template) → grava `messages`

Cliente responde no WhatsApp ─► Leona (fluxo de entrada) ─HTTP─► n8n WF-04 Atendimento IA
      → contexto do Supabase + base de conhecimento → resposta OU handoff
      → Leona envia a resposta / transfere para humano (9–20h) ou fila (fora do horário)
      → grava `messages` e `handoffs`
```

### Por que as regras críticas ficam em SQL (Supabase) e não em nós do n8n
`apply_event()` e `claim_due_actions()` são funções transacionais. "Pagou → cancela" acontece na mesma transação que grava o pagamento, e o dispatcher reavalia a condição no momento de pegar a ação. Se o n8n cair, reiniciar ou duplicar uma execução, o estado continua correto.

## 4. Régua de Pix (padrão inicial, configurável em tabela)

Base real: o Pix vale 15 min; 95% de quem paga, paga em até 4 min.

| Passo | Quando | Conteúdo | Janela |
|---|---|---|---|
| 1 | T+6 min (Pix ainda válido) | "Seu Pix de {produto} ainda está ativo por ~9 min" + código copia e cola | Sempre (o cliente acabou de agir) |
| 2 | T+20 min (Pix expirou) | "Seu Pix expirou. Gere um novo aqui: {link do checkout}" | Sempre |
| 3 | T+3 h | Lembrete + link | 8h–21h (senão vai para as 8h) |
| 4 | T+24 h | Último lembrete + link | 8h–21h |

- **Holdout de 10%**: sorteio fixo por contato. Quem cai no holdout não recebe nada, mas é registrado. É o que vai provar quanto a régua recupera de verdade, acima dos ~15% que voltam sozinhos.
- Máximo de 1 régua ativa por contato; nova compra paga de qualquer produto encerra as réguas de cobrança do contato.
- Resposta do cliente pausa a régua (a conversa passa para a IA ou para um humano).
- Opt-out ("parar", "sair", "não quero"): cancela tudo e suprime o contato.

## 5. Pós-compra
- Disparo: `paid` (Pix ou cartão). Envio imediato.
- Conteúdo: confirmação, **o mesmo link que a GGCheckout já entrega hoje** para aquele produto, como abrir o Drive no celular, onde está o e-mail e o horário de suporte.
- Nenhuma oferta nesta mensagem na sexta (upsell e cross-sell ficam para depois da autorização).

## 6. Atendimento IA
- Entrada: qualquer mensagem recebida no número.
- Contexto: status dos pedidos do telefone (Supabase), produto comprado e link de acesso.
- **Base de conhecimento** (tabela `kb_articles`, aprovada pelo Ruan): acesso ao Drive, "não recebi", como baixar no celular, o que contém cada kit, pagamento Pix, garantia e reembolso, horário de atendimento.
- Regra: a IA responde **somente** se houver artigo que cubra a pergunta; responde em até 3 frases; nunca promete reembolso, desconto ou prazo. Transfere quando: não há cobertura, o cliente pede humano, pede reembolso, reclama/está irritado, manda comprovante ou arquivo, ou após 2 respostas sem resolver.
- Handoff:
  - **9h–20h**: move a conversa para "aguardando atendente" no Leona, avisa a equipe e registra em `handoffs`.
  - **Fora do horário**: "Nosso atendimento humano funciona das 9h às 20h. Registrei sua mensagem e alguém vai te responder a partir das 9h." Registra com status `queued`. Às 9h, aviso à equipe com a fila.

## 7. Tabelas mínimas (subconjunto do modelo completo, mesmos nomes)
`contacts`, `orders`, `order_items`, `webhook_inbox`, `events`, `sequences`, `sequence_steps`, `enrollments`, `scheduled_actions`, `messages`, `conversations`, `handoffs`, `kb_articles`, `settings`. Todas com `workspace_id`.

## 8. Workflows n8n
| WF | Função |
|---|---|
| WF-01 Ingestão GGCheckout | Webhook → valida o secret → `webhook_inbox` → RPC `apply_event` |
| WF-02 Dispatcher | Cron de 1 min → `claim_due_actions` → confirma na GGCheckout → Leona → `messages` |
| WF-03 Reconciliação | Cron de 5 min → API de pagamentos (últimas 2 h) → eventos perdidos |
| WF-04 Atendimento IA | HTTP do Leona → contexto + base → resposta ou handoff → logs |
| WF-05 Fila de handoff | Cron às 9h → avisa a equipe dos casos em fila |
| WF-06 Alarme | Webhook sem evento por 2 h em horário comercial, falha de envio ou fila parada → alerta |

## 9. Testes antes de ligar
1. Eventos de teste da GGCheckout (`test_webhook`) para cada tipo.
2. **Compra real ponta a ponta** num produto de teste de R$ 1–5 (a criar como **rascunho não publicado**, com autorização) usando o telefone da equipe: (a) gerar Pix e não pagar → receber os passos 1 e 2; (b) gerar Pix e pagar em 2 min → **não** receber cobrança e receber o pós-compra.
3. Webhook duplicado e fora de ordem → sem efeito colateral.
4. Pagamento com webhook desligado → reconciliação cancela a régua em até 5 min, e o guard impede o envio.
5. IA: 20 perguntas (10 cobertas e 10 não cobertas) → 100% das não cobertas transferidas.
6. Handoff às 10h e às 22h.

Ligar com **limite de volume no primeiro dia** (ex.: só pedidos da linha Atualiza) e depois abrir para tudo.

## 10. Caminho crítico (o que pode impedir a sexta)
| Item | Dono | Prazo |
|---|---|---|
| **Número de WhatsApp do produto conectado ao Leona via Meta Cloud** | ntjautomacao / Ruan | Qua |
| **Templates aprovados na Meta** (pix_ativo, pix_novo_link, pix_lembrete, pos_compra_acesso) — categoria utilidade | ntjautomacao | Enviar qua; aprovação leva de minutos a 24 h |
| **Leona: como o n8n dispara um template/fluxo para um telefone** (API ou gatilho por webhook) | ntjautomacao, verificar no painel | Qua |
| Projeto Supabase | ntjautomacao | Qua |
| Webhook na GGCheckout apontando para o n8n (criação aditiva, não mexe em produto) | Autorização → Claude configura | Qui |
| Textos das mensagens + base de conhecimento aprovados pelo Ruan | Ruan | Qui 12h |
| URL pública de cada checkout (para o link de novo Pix) | Painel GGCheckout | Qui |
