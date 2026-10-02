# Propostas aguardando aprovação (antes de qualquer criação)

> Nenhum destes itens foi criado. Sem credenciais neste documento.
> Infraestrutura 100% isolada de outras operações: Supabase, n8n, Leona e número de WhatsApp novos (a criar pela ntjautomacao).

---

## A. Webhook da GGCheckout → n8n (INFORUAN)

### A.1 O que será criado (uma única chamada `create_webhook`)
| Campo | Valor proposto |
|---|---|
| Nome | `INFORUAN — Motor n8n — v1` |
| URL | `https://<n8n-inforuan>/webhook/gg/<sufixo-aleatório-longo>` (pendente: a instância nova do n8n ainda não existe) |
| Produtos | **Todos** (filtro vazio). Produtos novos entram automaticamente; o motor decide o que processar |
| Segredo | Gerado localmente num arquivo temporário (`chmod 600`) e enviado à GGCheckout por script, **sem aparecer no terminal nem no chat**. O ntjautomacao copia o valor para a credencial do n8n, e o arquivo é apagado |
| Eventos | `pix.generated`, `pix.paid`, `pix.expired`, `pix.failed`, `pix.refunded`, `card.generated`, `card.pending`, `card.paid`, `card.failed`, `card.expired`, `card.refunded` |

**Ponto de atenção**: a central de ajuda documenta `pix.*` / `card.*`, e a conta real confirma esse esquema (disparos `pix_paid`, `webhook_pix_generated` etc.). Já o MCP sugere `payment.*` no exemplo. **Antes de criar, preciso de um print da tela Configurações → Webhooks → Adicionar** mostrando os nomes exatos das caixas de evento, e se existe um evento de lead/checkout iniciado. Se houver evento de lead, ele entra na lista.

### A.2 Garantias de "nada existente alterado"
- Hoje a conta tem **0 webhooks** (confirmado via `list_webhooks`).
- Depois da criação: `list_webhooks` deve retornar exatamente 1 item, com o ID criado; `list_checkouts` e `list_products` devem continuar idênticos (comparação por hash antes e depois). Informo o ID e o resultado da comparação.

### A.3 Desenho do endpoint (n8n WF-01)
```
POST /webhook/gg/<sufixo>
  1. Code: valida o segredo (Bearer ou x-secret), comparação em tempo constante
       inválido → 401, sem gravar corpo nem headers
  2. Code: remove Authorization / x-secret / cookie dos headers
  3. Supabase RPC ingest_webhook(source='ggcheckout', dedupe_key, headers_limpos, payload)
       dedupe_key = sha256(event | payment.id | payment.status)
       INSERT ... ON CONFLICT (source, dedupe_key) DO NOTHING
  4. Respond 200 {received:true}   ← GGCheckout recebe resposta em < 1 s
─────────────────────────────────────────────────────────────
WF-01b Processador (separado; cron a cada 15–30 s ou gatilho do banco)
  claim_inbox_batch() [FOR UPDATE SKIP LOCKED] → apply_event() → marca processed_at / error
```
- **Idempotência** em duas camadas: `dedupe_key` único na entrada e transições monotônicas em `apply_event` (pago nunca volta a pendente).
- **Logs sem segredo**: no WF-01, desligar "Save execution data" (sucesso e erro) no n8n, porque o n8n grava os headers da requisição. O rastro fica em `webhook_inbox`, já com os headers limpos. Os erros vão para `webhook_inbox.error`, sem payload sensível.
- Retentativas da GGCheckout (3×) viram duplicatas ignoradas.

---

## B. Checkout de teste ponta a ponta

### B.1 Base: oferta mais vendida nas últimas 72 h
| Oferta | Pedidos pagos (72 h) |
|---|---|
| **Kit Completo Atualiza 40+** (checkout `dDTs0…`, produto `EuwGEZ…`) | **144** |
| Finanças 40+ — Kit Completo | 94 |
| Kit Básico Atualiza 40+ | 20 |
| Finanças 40+ — Kit Básico | 17 |

### B.2 O que será criado (alternativa menos invasiva: **novo checkout do mesmo produto**, sem duplicar produto)
| Campo | Valor |
|---|---|
| Título | `[TESTE E2E — NÃO PUBLICAR] Kit Completo Atualiza 40+` |
| productId | `EuwGEZ…` (o mesmo produto; **o produto não é alterado**) |
| `published` | **false** |
| Preço | R$ 5,00 (proposta: reduz o custo das compras de teste. O fluxo e o payload são idênticos, só muda o valor. Alternativa: R$ 37, igual ao real) |
| Pagamento | Mesmos gateways por referência de ID (Mercado Pago no Pix, Stripe no cartão). Nenhum segredo trafega |
| Campos | nome, e-mail e telefone (igual ao original) |
| Order bumps | Os mesmos 5 (só referência aos produtos; nada neles muda) |
| **Pixels/UTMify (`metricToken`)** | **Nenhum**. Evita que a compra de teste envie "Purchase" para o Meta e a UTMify e contamine a otimização das campanhas |
| Tag do checkout | `internal_test` (via `manage_checkout_tags`, só no checkout novo) |

### B.3 Como garantir que fica inativo
1. Criação com `published:false`. Depois confiro com `get_checkout` que `published=false`. Se voltar `true`, **apago imediatamente** e reporto.
2. A GGCheckout não cria checkout na loja (o produto já tem `published:false`, e o checkout não altera o produto).
3. Nenhum tráfego: o link não vai para nenhuma campanha, página ou mensagem, só para o celular de teste.
4. **Incerteza a validar**: não há documentação sobre um checkout não publicado **aceitar pagamento**. Se o link bloquear o pagamento, **paro e reporto**. Não publico sem nova autorização.
5. No motor: pedidos do `checkoutId` de teste e dos telefones internos (`settings.internal_test_phones`) recebem `is_internal_test=true` → ficam fora do holdout, das métricas e do dashboard. **Ainda aparecem no painel da GGCheckout**, porque não há como excluir lá.
6. Depois do teste: estorno manual das compras de teste pelo Ruan, e registro manual de reembolso no motor.

---

## C. Holdout (grupo de controle) — desenho

| Decisão | Proposta | Por quê |
|---|---|---|
| **Unidade de alocação** | **Contato** (telefone E.164 normalizado; e-mail como alternativa) | A mesma pessoa gera vários Pix; alocar por pedido faria ela cair nos dois grupos |
| Regra | `hash(salt_do_experimento + contato) mod 100 < 10` → controle | Aleatória, estável, reproduzível, sem sorteio a cada evento |
| Momento do registro | Na matrícula (`pix.generated`), **antes de qualquer envio**, em `experiment_assignments` (único por experimento e contato) | Atende "registrada antes do primeiro envio" |
| **População elegível (ITT)** | Contatos com Pix **ainda não pago no instante do 1º passo (T+6 min)**, com telefone válido, sem opt-out, não internos. O **mesmo critério** vale para os dois grupos | Quem paga em 4 min nunca seria tocado; incluí-lo só dilui o efeito. A elegibilidade é definida antes e igual para tratado e controle, então continua sendo intenção de tratar |
| Reentrada | O contato mantém o grupo por todo o experimento. Um novo Pix não sorteia de novo | Estabilidade |
| O que o controle recebe | **Nada da régua de Pix.** Continua recebendo pós-compra, suporte/IA e mensagens obrigatórias | Conforme aprovado |
| **Métrica principal** | % de contatos elegíveis com **qualquer pedido pago em até 72 h** após a elegibilidade | A régua dura 24 h; 72 h captura a cauda |
| Secundárias | Receita líquida por contato elegível (72 h); o mesmo em 7 dias; opt-out; bloqueios e denúncias do número | Receita incremental = (tratado − controle) × elegíveis tratados |
| **Período mínimo** | **4 semanas completas** e **≥ 70 contatos no controle**, o que vier por último | Ver cálculo abaixo |
| Leitura | Bayesiana (probabilidade de a régua ser melhor + intervalo do lift), com checagem semanal **sem encerrar antes do mínimo** | Evita parar no primeiro dia bom |

**Cálculo do período** (ritmo atual: ~116 pedidos/dia e ~20 elegíveis/dia; base de volta natural ~12% em 72 h):
- Para detectar +12 p.p. (12% → 24%) com 80% de poder e divisão 90/10, são necessários ~690 elegíveis, ou **~5 semanas**.
- Com +8 p.p., seriam ~1.500, ou ~10 semanas.
- Opção para acelerar (exige nova aprovação): holdout de 20% nas 3 primeiras semanas, o que exige ~410 elegíveis (~3 semanas).
- Se o volume de mídia subir, o prazo cai na mesma proporção.

---

## D. Leona — critérios para analisar os prints

| Requisito | O que procuro no print |
|---|---|
| n8n pede o envio de um template para um telefone | Endpoint de API (REST) ou gatilho de fluxo por webhook que aceite telefone + template/variáveis |
| Receber mensagens e status | Webhook de saída com eventos de mensagem recebida, enviada, entregue, lida, falha |
| Identificar conversa e contato | IDs de chat/contato e telefone no payload; busca de contato por telefone |
| Transferir para a inbox humana | Endpoint ou nó de fluxo que muda status, fila ou atendente, chamável de fora |

**Se faltar o envio externo**, as alternativas, para decidir antes de implementar:
1. **Fluxo do Leona disparado por webhook de entrada** (se existir) com um nó Template. O n8n só chama a URL do fluxo com telefone e variáveis.
2. **n8n chama direto a Cloud API da Meta** com o token do WABA do INFORUAN (se o número estiver num WABA próprio, com usuário de sistema). As respostas continuam chegando ao Leona. Risco: mensagens enviadas fora do Leona podem não aparecer no histórico da inbox, e é preciso registrar no Supabase.
3. **Trocar o canal por um BSP oficial com API completa** e inbox própria (ex.: 360dialog/Twilio + Chatwoot). Custo de migração maior; só se 1 e 2 falharem.
4. Evolution API: **fora**, conforme a decisão.

> Observação de isolamento: o MCP do Leona hoje conectado a esta sessão é **de outra operação**. Não será usado para nada do INFORUAN. A conta nova do Leona precisa de uma credencial MCP própria se você quiser que eu opere nela.
