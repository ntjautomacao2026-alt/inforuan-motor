# Diagnóstico da conta GGCheckout (dados reais)

> Extraído em 2026-09-30 via MCP e API da GGCheckout, **somente leitura**.
> Base: 7.710 de 7.838 pagamentos (98%), de 26/08 a 30/09/2026. Nenhum dado pessoal foi gravado; a análise usou só agregados e hashes.

## 1. Números principais

| Métrica | Valor |
|---|---|
| Pedidos gerados | 7.710 |
| Pedidos pagos | 6.365 (82,6%) |
| Receita paga | R$ 271.069 |
| Ticket médio | R$ 42,59 |
| Pix / cartão (pagos) | 90% / 10% (5.725 / 640) |
| Aprovação de cartão | 98% |
| Taxa GGCheckout | 3,1% (3% + R$ 0,49) |
| **Pedidos não pagos** | **1.332 (17,3%) = R$ 57.101** |
| Não pagos com telefone e e-mail | 1.331 (99,9%) |
| Não pagos que voltaram e compraram **sozinhos** em até 7 dias | 15,2% (R$ 8.666) |
| Compradores únicos (aprox.) | ~6.029 |
| Recompra (2+ compras) | 5,1% |
| Compraram as duas linhas (Finanças e Atualiza) | 224 |
| Reembolsos / chargebacks registrados | 0 / 0 (suspeito, ver §5) |
| Origem do tráfego | 97,6% Meta (FB/IG) |

**Tendência**: pico de ~400 vendas/dia entre 13 e 20/09; queda para ~80–125/dia entre 26 e 29/09.

## 2. Catálogo e esteira atual

| Oferta principal | Preço | Pedidos pagos | Com bump | Ticket |
|---|---|---|---|---|
| Finanças 40+ — Kit Completo (+4 bônus) | R$ 37 | 3.690 | **45%** | R$ 45,75 |
| Kit Completo Atualiza 40+ | R$ 37 | 1.816 | **37%** | R$ 43,01 |
| Finanças 40+ — Kit Básico | R$ 19,90 | 480 | 21% | R$ 24,10 |
| Kit Básico Atualiza 40+ | R$ 19,90 | 226 | 24% | R$ 23,40 |
| Meu Consultor Financeiro 40+ | R$ 47 | 153 | — | R$ 47,59 |

- **Order bumps** (R$ 9,90–12,90) funcionam bem nos kits completos.
- **Nenhum upsell/downsell one-click configurado** (`isUpsell = false` em 100% dos pedidos).
- "Meu Consultor Financeiro 40+" (R$ 47) **é o upsell** da linha Finanças, feito como **checkout separado sem campos** (decisão para não obrigar o cliente a preencher de novo). Take rate ≈ **3,7%** (153 / 4.170 compradores da linha Finanças). Efeitos colaterais:
  - a compra do upsell **não fica ligada ao cliente** ("Cliente Checkout", e-mail `@noreply`) → LTV, suporte, reembolso e remarketing ficam cegos para ela;
  - o cliente paga **um segundo Pix do zero**, que é o maior atrito do fluxo;
  - os 12 Pix não pagos do upsell não têm como ser recuperados.
  - **Alternativa nativa**: o upsell da GGCheckout (`create_upsell`, vinculado ao produto principal) reaproveita os dados da compra, também sem pedir nada ao cliente, e grava `isUpsell`/`originalPaymentId`. Mantém a agilidade e resolve a identidade. Hoje há 0 upsells nativos cadastrados.
- Não existem funis, área de membros ativa nem webhooks configurados.

## 3. Comportamento do Pix (muda o desenho da régua)

- **A validade do Pix é de 15 minutos** em 100% dos pedidos.
- Tempo até pagar: mediana 1,2 min; p90 2,8 min; p95 3,9 min; p99 8,8 min. **Só 0,7% pagam depois de 10 min.**
- Conclusão: uma mensagem em T+10 min chega quando o Pix está quase vencendo, e quase ninguém paga o mesmo Pix depois disso. **A recuperação precisa gerar um novo Pix (novo link de checkout).**
- O webhook `pix_expired` foi disparado em só **909 dos 1.332** não pagos (68%). **A expiração tem de ser derivada por timer** (`createdAt + expiresAt` sem pagamento), sem depender do webhook.

## 4. Horário
Pedidos concentrados entre **6h e 10h (BRT)**, com pico às 7–8h. O público tem 40+ anos. Janela de envio sugerida: 7h–21h.

## 5. Achados de risco

1. **Vazamento de entrega (receita)**: o Kit Básico e o Kit Completo de cada linha, **e todos os order bumps**, entregam **o mesmo link de pasta do Google Drive**. Quem compra o básico por R$ 19,90 provavelmente recebe tudo, inclusive os bumps. Isso também anula qualquer upsell Básico → Completo. _Precisa ser verificado abrindo as pastas._
2. **Nenhuma recuperação rodando**: houve um teste da recuperação nativa (provedor **WAHA, não oficial**) só em 22/09, em 46 pedidos, com as mensagens paradas como "queued". Depois a sessão foi removida.
3. **Reembolso**: confirmado pelo produtor, foram no máximo ~5, feitos **manualmente na conta dele**, fora da GGCheckout. A taxa (~0,08%) é irrelevante hoje, mas esses pedidos continuam como "pago" na GGCheckout → o motor precisa de **registro manual de reembolso** para tirar o cliente de ofertas e corrigir receita e LTV.
4. **A API mascara e-mail, telefone e CPF.** O contato só chega **pelo webhook**. A base histórica (~6 mil compradores) só pode ser importada por **exportação CSV do painel**.

## 6. Integração: o que foi confirmado

| Item | Resultado |
|---|---|
| Esquema de eventos | **`pix.*` / `card.*`** (disparos internos: `webhook_pix_generated`, `pix_paid`, `pix_expired`, `webhook_card_generated`, `card_paid`) |
| Gateways | Pix: Mercado Pago. Cartão: Stripe. Boleto: não usado |
| Campos disponíveis no pagamento (API) | `expiresAt`, `finalValueInCents`, `mainProductCents`, `orderBumps[]`, `platformFeeInCents`, `fixedFee`, `fbc`, `fbp`, `trackProps.params` (utm_*, src, sck, fbclid), `checkoutId`, `productId`, `titleOffer`, `gatewayPaymentId`, `recovery`, `whatsappDeliveries` |
| UTMs | Vêm no formato `nome\|id` (ID de campanha/conjunto/anúncio do Meta) → **dá para cruzar com o gasto por anúncio** |
| Paginação da API | Máximo de 100 por página, cursor `lastCreatedAt`. Sem bloqueio de anti-bot via Node |
| Área de membros (API) | Não autorizada (não habilitada) |
| Pixels / CAPI | 2 pixels Meta em modo "both" + UTMify, já funcionando |

## 7. Tamanho da oportunidade (estimativa, volume de setembro)

| Alavanca | Premissa | Receita/mês |
|---|---|---|
| Recuperação de Pix não pago | ~1.150 não pagos/mês; lift **incremental** de 8–15 p.p. sobre a volta natural de 15% | R$ 4–7 mil |
| Upsell one-click nativo pós-compra (ex.: Consultor R$ 47 ou kit da outra linha) | ~5.400 compradores/mês × 8–12% de take rate × R$ 37–47 | R$ 16–30 mil |
| Cross-sell para a base (Finanças ↔ Atualiza) | ~6 mil compradores; 5–8% de conversão × R$ 37 | R$ 11–18 mil (pontual) + recorrente |
| Corrigir o vazamento de entrega do Kit Básico | Desbloqueia o upsell Básico → Completo | — |

> Estimativas para priorizar, não previsões. O volume atual está ~60–70% abaixo do pico, e os valores escalam com ele.
