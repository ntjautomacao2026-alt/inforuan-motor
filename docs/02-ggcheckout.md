# GGCheckout: o que conseguimos receber e consultar

> Pesquisa de 2026-09-30 em documentação pública. **Atualização**: vários pontos em aberto foram validados na conta real via MCP/API. Ver [`03-diagnostico-conta.md`](03-diagnostico-conta.md) §6. Confirmado: esquema `pix.*`/`card.*`, Pix com validade de 15 min, `pix_expired` disparado em só 68% dos casos, API mascarando e-mail, telefone e CPF, e paginação limitada a 100.
> Legenda: **[C]** confirmado em fonte oficial · **[I]** inferido · **[?]** não encontrado (validar no painel)

## Conclusão em 6 linhas
1. **Webhooks cobrem o essencial de recuperação**: Pix gerado/pago/expirado/falho/reembolsado e cartão gerado/pendente/pago/recusado/expirado/reembolsado. [C]
2. **Checkout abandonado existe** como "Novo lead" no webhook, mas o nome técnico, o payload e o momento do disparo são [?].
3. **Existe API REST** (não documentada formalmente, via repositório oficial do MCP), com listagem paginada de pagamentos, detalhe do pagamento, verificação no gateway e dados de alunos da área de membros. Isso permite **reconciliação** e **enriquecimento** do webhook. [C]
4. **A GGCheckout já faz parte do que queremos**: recuperação de Pix por WhatsApp, order bump, **upsell/downsell one-click**, Meta CAPI, TikTok Events API, Google Enhanced Conversions, UTMify e área de membros. [C] **Não devemos reconstruir isso, devemos orquestrar e medir.**
5. **Há dois esquemas de webhook conflitantes** nas fontes oficiais (`pix.*`/`card.*` vs. `payment.*`). O adapter precisa aceitar os dois até validarmos no painel.
6. **Confiabilidade limitada**: só 3 retentativas, histórico de 7 dias, API sem especificação formal e com breaking changes, unidades mistas (reais vs. centavos). Idempotência + reconciliação são obrigatórias.

## Eventos de webhook → eventos canônicos do motor

| GGCheckout | Status | Evento canônico | Efeito no motor |
|---|---|---|---|
| "Novo lead" (checkout iniciado) | [C] categoria, nome técnico [?] | `checkout.started` | Timer de abandono (ex.: 15 min sem pedido → `checkout.abandoned`) |
| `pix.generated` | [C] | `order.pix_generated` | Matricula em `recovery.pix` |
| `pix.paid` / `card.paid` | [C] | `order.paid` | **STOP recuperação**, onboarding, esteira |
| `pix.expired` | [C] | `order.pix_expired` | Troca para `recovery.pix_expired` |
| `pix.failed` | [C] | `order.payment_failed` | `recovery.pix_failed` |
| `card.generated` / `card.pending` | [C] | `order.pending` | Aguarda (sem mensagem) |
| `card.failed` | [C] | `order.card_declined` | `recovery.card` (oferecer Pix) |
| `card.expired` | [C] | `order.expired` | `recovery.card` |
| `pix.refunded` / `card.refunded` | [C] | `order.refunded` | Sai de tudo que é comercial, flag |
| status `charged_back` | [C] status, evento dedicado [?] | `order.chargeback` | Sai de tudo, bloqueia ofertas |
| Boleto | [?] não há `boleto.*` | — | Fora do MVP até confirmar |
| Assinatura | [?] | — | V3 |
| Upsell/downsell | [C] pagamento separado com `isUpsell` e `originalPaymentId` (API) | `order.paid` com `parent_order_id` | Take rate da esteira |
| Order bump | [C] no mesmo pagamento, `products[].type = "orderbump"` | `order_items.role = bump` | AOV |

## Payload documentado (`pix.paid`)
Campos: `event, createdAt, customer{name,email,document,phone,ip}, payment{id,method,paymentMethod,gateway,status,amount,pixCode}, product{id,type,title}, products[], webhook{id,businessId,events}, utm_source, utm_medium, utm_campaign, utm_content, utm_term, customerIp`.

**Faltam no webhook** (mas existem na API, via `GET /payments/{id}`): `expiresAt` (validade do Pix), cupom/descontos, `orderBumps`, `isUpsell`/`originalPaymentId`, taxas (`platformFeeInCents` etc.), `finalValueInCents`, `trackProps`, `utmify`, `titleOffer`.
→ **Estratégia**: webhook dispara, adapter enriquece via API (com rate limit de 30 req/min).

**Faltam em ambos** [?]: `src`/`sck`, `fbc`/`fbp`, URL/ID do checkout, parcelas.

## Autenticação
- Central de ajuda: secret opcional enviado como `Authorization: Bearer <secret>` e `x-secret`. [C]
- MCP: `X-Webhook-Signature: sha256=HMAC(...)`. [C, mas as fixtures são locais]
- Adapter aceita os dois; exigir secret configurado.

## API REST
- Base `https://ggcheckout.app`, `Authorization: Bearer ggck_live_...` (gerada em Configurações → MCP/API Key).
- `GET /api/me` → `businessId`
- `GET /api/get-clients/business/{businessId}/payments/paginated`, com `dateFrom`, `dateTo`, `lastCreatedAt`, `status` e `searchTerm` → **reconciliação** a cada 5–10 min e backfill histórico
- `GET .../payments/{id}` → enriquecimento
- `POST /api/payments/check-payment/{id}` → confirmar status no gateway antes de enviar cobrança (guard extra, opcional)
- `/api/members-area/*` → `firstAccess`, `progress`, `status` do aluno → **sinal de consumo** para onboarding e elegibilidade de upsell (polling)
- `/api/funnels` (leads), `/api/checkouts`, `/api/discounts`, `/api/whatsapp/*`
- Rate limit: 30/min e 1.000/h por chave. Sem OpenAPI. Houve breaking changes.

## Recursos nativos que se sobrepõem ao motor

| Recurso nativo | Decisão proposta |
|---|---|
| Recuperação de Pix por WhatsApp (`pix_unpaid`, `pix_expired`, delays, janela de horário, máx. mensagens) | **Não rodar os dois ao mesmo tempo** (mensagem duplicada, sem holdout e sem atribuição). Proposta: desligar a nativa quando o motor estiver no ar e usá-la como **baseline** antes disso. |
| Order bump e upsell/downsell one-click | **Manter na GGCheckout** (converte no momento de maior intenção). O motor configura a esteira, mede o take rate e faz o **follow-up de quem recusou** por WhatsApp/e-mail. |
| Meta CAPI / TikTok / Google server-side | **Manter nativo.** Remove CAPI do nosso escopo. O motor só sincroniza **públicos** por estágio (V2). |
| Área de membros e entrega | Manter. O motor lê o progresso via API para onboarding e elegibilidade. |
| E-mails transacionais (provedores integrados) | Entrega/acesso continuam na GGCheckout; e-mails de régua saem do motor. |
| UTMify | Pode continuar como visão de tráfego; o motor é a fonte de LTV e recuperação. |

## Riscos específicos
- Esquema de evento ambíguo, que precisa ser confirmado no painel.
- 3 retentativas e histórico de 7 dias → reconciliação obrigatória.
- Unidades mistas (`amount` em reais, `price` em centavos) → normalizar tudo para centavos no adapter.
- Plataforma com reputação fraca no ReclameAqui (nota 4,2, "não recomendada") e rotatividade de gateways → adapter isolado para permitir troca de checkout.
- Reembolso depende do gateway notificar a GGCheckout.
- Taxas (pricing de 16/09/2026): Split 3%; Billing 3% + R$0,49.

## Validar no painel (checklist)
1. Nomes exatos dos eventos na tela de webhooks (`pix.*`/`card.*` ou `payment.*`).
2. Nome técnico, payload e momento de disparo do "Novo lead". Exige e-mail/telefone?
3. Eventos de boleto, chargeback, assinatura e acesso à área de membros.
4. Formato de autenticação e botão de evento de teste.
5. O webhook traz `originalPaymentId`, cupom, parcelas, taxas, `src`/`sck`, validade do Pix?
6. `amount` em reais ou centavos em cada evento.
7. A validade do Pix é configurável? Qual é a atual?
8. Intervalo de retentativa e reenvio manual.
9. Qual gateway a conta usa hoje.
10. Permissões da API key (leitura ou total).
11. A recuperação nativa está ligada hoje? Com quais mensagens e resultados?

## Fontes
- https://docs.ggcheckout.com/help/vendedor/integracoes/estrutura-do-payload-do-webhook
- https://docs.ggcheckout.com/help/vendedor/integracoes/webhooks-personalizados
- https://docs.ggcheckout.com/help/vendedor/integracoes/facebook-pixel-e-meta-ads
- https://docs.ggcheckout.com/help/vendedor/integracoes/google-ads-pixel-de-conversao
- https://docs.ggcheckout.com/help/vendedor/integracoes/integracao-com-whatsapp
- https://docs.ggcheckout.com/help/vendedor/checkout-e-conversao/configurando-upsells-e-downsells
- https://docs.ggcheckout.com/help/vendedor/checkout-e-conversao/analytics-de-conversao
- https://docs.ggcheckout.com/help/vendedor/financas/configurando-metodos-de-pagamento
- https://github.com/ggCheckout/ggcheckout-mcp
- https://www.ggcheckout.com/llms.txt · https://www.ggcheckout.com/pricing.md · https://www.ggcheckout.com/pt/terms
- https://www.ggcheckout.com/pt/blog/ggcheckout/novidades-ggcheckout-julho-2026 · .../agosto-2026
- https://www.reclameaqui.com.br/empresa/ggcheckout/lista-reclamacoes
