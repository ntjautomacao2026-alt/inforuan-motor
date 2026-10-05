# Provedor de WhatsApp — comparação e recomendação

> 05/10/2026. **Decisão pendente do usuário.** Nada foi contratado, criado ou conectado.
> Preços e regras da Meta mudam a cada trimestre: conferir no painel antes de contratar.

## 1. O que o motor precisa do canal

- **Mensagens iniciadas pela empresa** para quem gerou Pix e não pagou (recuperação) e para quem pagou (acesso). Ninguém mandou mensagem antes, então na API oficial isso exige **template aprovado**.
- **Receber respostas** e **status** (enviada, entregue, lida, falha), que alimentam a fila, a IA e o "pagou → para".
- **Atendimento humano das 9h às 20h** no mesmo número, com o motor **percebendo quando um humano respondeu**, para silenciar a IA (handoff explícito; já implementado no banco).
- Volume real (doc `03`, 26/08 a 30/09):
  - média de ~220 pedidos/dia, sendo **~38 Pix não pagos/dia** e **~180 pagos/dia**;
  - nos últimos dias, ~80 a 125 pagos/dia (cerca da metade);
  - **R$ 57 mil/mês em Pix não pagos**.

## 2. Regras da Meta que pesam na escolha (2026)

| Regra | Efeito |
|---|---|
| Cobrança **por mensagem entregue**, por categoria. Tabela em reais desde 01/07/2026: **marketing R$ 0,3217**, **utilidade R$ 0,0350**, autenticação R$ 0,0350 | Lembrete de carrinho ou checkout abandonado costuma ser classificado como **marketing**, que custa ~9× a utilidade. **Quem decide a categoria é o classificador da Meta**, não nós |
| **A partir de 01/10/2026**: respostas de atendimento (dentro da janela de 24 h) e templates de utilidade enviados dentro da janela passam a ser cobrados, com **1.000 respostas grátis por mês por número** | Anunciado por parceiros da Meta (Zenvia, Twilio e outros). A página da Meta lida hoje ainda não mostra; **confirmar no painel** |
| Limite inicial: **250 pessoas por 24 h** em mensagens iniciadas pela empresa, subindo para 2 mil, 10 mil… conforme verificação e qualidade. Desde 10/2025, o limite vale **por portfólio (Business Manager)**, não por número | ~38 recuperações/dia cabem com folga. O portfólio tem de ser **próprio do INFORUAN** (ntj/Ruan), nunca o da outra operação: além do isolamento, o limite seria dividido |
| **Coexistência** (mesmo número na API e no app WhatsApp Business): disponível no Brasil, mas **só é ativada por um parceiro oficial** (Solution Partner / Tech Provider), e o número precisa estar **em uso no app há ≥ 7 dias** | É o jeito mais simples de a equipe atender pelo celular enquanto o motor automatiza. O motor recebe o eco das mensagens enviadas pelo app e abre o handoff |

## 3. Opções

| | **A. API oficial via parceiro com coexistência** (ex.: 360dialog) | **B. API oficial direta da Meta** | **C. Não oficial via QR** (Evolution, WAHA, Z-API) | **D. WhatsApp nativo da GGCheckout** |
|---|---|---|---|---|
| Oficial / risco de banimento | Oficial | Oficial | **Não oficial**: viola os termos; alto risco ao mandar para quem nunca falou com o número | **Não oficial** (usa WAHA) |
| Custo fixo | 360dialog: **€ 49/mês por número**, sem margem sobre a Meta. Twilio: US$ 0,005/msg. Gupshup: US$ 0,001/msg | Nenhum | Baixo (servidor e/ou ~R$ 100/mês) | Incluso na GGCheckout |
| Custo por mensagem | Tabela da Meta | Tabela da Meta | Nenhum | Nenhum |
| Atendimento humano no celular | **Sim, coexistência** | **Não**, a coexistência exige parceiro. Seria preciso uma caixa de atendimento (ex.: Chatwoot), ou seja, mais infraestrutura | Sim | Não integrado ao motor |
| Encaixa no motor (fila, guard, holdout, IA, handoff) | Sim | Sim | Sim | **Não**: sem holdout, sem IA e sem atribuição |
| Templates e aprovação | Sim | Sim | Não precisa | Não precisa |
| Observação | Onboarding guiado, suporte e "Embedded Signup" | Mais barato, porém mais burocrático e sem coexistência | O teste da GGCheckout com WAHA, em 22/09, ficou travado em "queued" | Hoje há **0 sessões** ativas, então não há risco de duplicar mensagens |

## 4. Custo estimado da opção A (tabela da Meta + € 49/mês)

Premissas:
- 90% dos não pagos recebem a régua (10% são grupo de controle), com ~3,6 mensagens cada;
- pós-venda de acesso para todo pagante;
- respostas da IA dentro da franquia de 1.000/mês.

| Item | Volume médio do período | Volume recente (~metade) |
|---|---|---|
| Recuperação: **pior caso, tudo marketing** | ~3.700 msg × R$ 0,3217 ≈ **R$ 1.190/mês** | ≈ R$ 600/mês |
| Recuperação: passos 1–2 aceitos como utilidade, 3–4 como marketing | ≈ R$ 660/mês | ≈ R$ 330/mês |
| Pós-venda (utilidade) | ~5.400 msg × R$ 0,035 ≈ **R$ 190/mês** | ≈ R$ 105/mês |
| Parceiro (360dialog) | € 49 ≈ R$ 300/mês (câmbio aproximado) | idem |
| **Total aproximado** | **R$ 1.150 a R$ 1.680/mês** | **R$ 735 a R$ 1.000/mês** |

**Referência:** R$ 57 mil/mês ficam em Pix não pagos, e 15,2% desse valor já volta sozinho. Recuperar **2 a 3 pontos percentuais** a mais já paga o canal. O **grupo de controle de 10%** mede o ganho real, já descontando quem voltaria sozinho.

**Alavancas de custo:**
- escrever os passos 1 e 2 como **aviso transacional** do pedido ("seu Pix do pedido X vence às HH:MM"), sem tom promocional, para tentar a categoria utilidade;
- avaliar cortar o passo 4 se o holdout mostrar retorno baixo.

## 5. Recomendação

**Opção A: API oficial via parceiro com coexistência.** O candidato principal é a **360dialog** (€ 49/mês, sem margem por mensagem, coexistência documentada). As alternativas são Gupshup e Twilio, com cobrança por mensagem. O motivo central é ter oficialidade, baixo risco de perder o número e atendimento humano no próprio celular, que o motor já sabe detectar, sem montar uma caixa de atendimento.

As opções **C e D estão descartadas** para o motor: não são oficiais e trazem risco ao número. A D também fica fora do holdout e da IA.

## 6. Caminho, se aprovado (passos do usuário; eu não crio contas)

1. **Número novo e exclusivo do INFORUAN** (chip próprio, nunca o da outra operação). Instalar o **WhatsApp Business** já, porque a coexistência exige ≥ 7 dias de uso.
2. **Portfólio da Meta (Business Manager) próprio do INFORUAN/ntj** + **verificação da empresa** (CNPJ e documentos). A verificação acelera os limites.
3. Conta no parceiro escolhido e **Embedded Signup com coexistência**, feitos por você.
4. Nome de exibição e **templates** submetidos (eu adapto os 9 rascunhos do banco ao formato da Meta; o **Ruan aprova o texto**).

**Engenharia (eu, com autorização em cada passo):**
- **0011:** processamento dos eventos da Cloud API (mensagens, status e ecos do app → handoff).
- **Edge Function `wa-webhook`:** autenticada, nos moldes da `gg-webhook`.
- **IR-04 Envio:** adaptador do parceiro (envio de template, classificação de erro, conferência de pagamento na GGCheckout antes de cobrar).
- **Health check** do número.
- Credenciais só no n8n e nos Secrets.

Tudo começa em modo **só internos**.

## Fontes

- Meta — preços da plataforma: https://developers.facebook.com/docs/whatsapp/pricing
- Meta — limites de mensagens: https://developers.facebook.com/documentation/business-messaging/whatsapp/messaging-limits
- Meta — Embedded Signup: https://developers.facebook.com/documentation/business-messaging/whatsapp/embedded-signup/overview/
- Zenvia — mudanças de 2026: https://zenvia.com/en/new-whatsapp-business-pricing-rules-for-2026/
- Twilio — preços WhatsApp: https://www.twilio.com/en-us/whatsapp/pricing
- Tabela em reais (Brasil, 2026): https://wizebot.com.br/blog/tabela-precos-whatsapp-business-api-2026
- 360dialog — preços: https://360dialog.com/pricing
- 360dialog — coexistência: https://docs.360dialog.com/docs/waba-management/the-360-client-hub/embedded-signup/whatsapp-coexistence
- Gupshup — preços: https://blog.campaignhq.co/gupshup-whatsapp-pricing
- Coexistência — requisitos (7 dias, parceiro): https://github.com/bellopushon/whatsapp-cloud-api/blob/main/skills/whatsapp-cloud-api/references/COEXISTENCE.md
- Categoria de lembrete de carrinho: https://chatmaxima.com/whatsapp-template-library/e-commerce/abandoned-cart-reminder/
