# Liberação 1 — recuperação de Pix (passo 1) para clientes reais

> **Status: texto aprovado pelo Ruan e configuração aplicada (0015 + 0016, 14/10/2026). Modo ainda `internal_only`: falta o teste no número interno e a autorização para `live`.** Decisões do usuário em 14/10/2026: começar **só pela recuperação, passo 1**; **esperar o Ruan aprovar o texto**; **o Ruan acompanha** as respostas no celular do número (31) 3157-6278. Telegram e IA ficam para depois.

## 1. O que vai ao ar

- **Gatilho:** Pix gerado e não pago. **6 minutos depois**, o cliente recebe no WhatsApp a mensagem "Pix ainda válido", com o código Pix Copia e Cola. O Pix vale 15 minutos.
- **Não vai ao ar ainda:**
  - passos 2 a 4 (novo link em 20 min, 3 h e 24 h), porque dependem dos links públicos dos checkouts;
  - pós-venda pelo WhatsApp: o e-mail de entrega da GGCheckout continua para todos;
  - IA e alertas no Telegram.
- **Grupo de controle (10%):** não recebe a mensagem, e serve para medir quanto ela recupera de verdade.

## 2. Proteções que já estão ativas

| Proteção | Como |
|---|---|
| Quem já pagou não recebe | Pagamento cancela a régua na hora + conferência na GGCheckout antes de cada envio |
| Limite de aquecimento | 2 mensagens/min, 30 s entre mensagens, **40/dia** (número não oficial) |
| WhatsApp caiu | Pausa automática e retomada sozinha; mensagem vencida não sai (validade de 8 min) |
| Rajada de erros | 3 erros em 5 min pausam os envios até liberação manual |
| Cliente respondeu | A régua dele para. **A conversa aparece no celular do número; o Ruan responde por lá.** O motor percebe a resposta humana e silencia a automação para esse cliente |
| "PARAR" | Descadastro imediato e confirmação |
| Nunca disparo para a base | Só quem gerou Pix nos últimos 30 dias; recusado pelo banco |

## 3. Texto para o Ruan aprovar (rascunho atual, testado em 14/10)

```
Oi, {nome}! Vi que você gerou o Pix do *{produto}* e ele ainda está ativo por alguns minutos.

Para concluir, copie o código abaixo e cole no app do seu banco, em *Pix Copia e Cola*:

{código Pix}

Se tiver qualquer dúvida, é só responder aqui.
```

**Sugestões para ele avaliar:**
- mandar o **código Pix numa segunda mensagem, sozinho**, para o cliente copiar com um toque longo. Hoje ele vai no meio do texto;
- incluir o **valor** ("R$ 37,00");
- tom e assinatura (nome do produto/marca).

## 4. Passos para ligar (cada um com autorização)

1. Ruan aprova ou ajusta o texto → eu atualizo o modelo `pix_ativo` no banco e testo com um número interno.
2. Aplicar a **0015**: só o passo 1 ativo; pós-venda pelo WhatsApp desligado.
3. **Ligar o modo `live`**: `set_engine_mode('inforuan', 'live', '<quem autorizou>')`.
4. Acompanhar a 1ª hora:
   - mensagens enviadas e entregues;
   - pagamentos depois da mensagem;
   - respostas;
   - nenhum envio a quem já pagou.

**Voltar atrás a qualquer momento:** `set_engine_mode('inforuan', 'internal_only', …)`. Clientes reais param de entrar na régua na hora, e o que já estava na fila é cancelado no envio.

## 5. Aprovação e configuração (14/10/2026)

- **Ruan aprovou o texto**, pedindo o **código Pix numa mensagem separada** (público 40+).
- **0015 (aplicada):** só o passo 1 ativo; `post_purchase_whatsapp = off`.
- **0016 (aplicada):**
  - `pix_ativo` v2 (texto aprovado, sem o código, avisando que ele vem logo abaixo);
  - `pix_codigo` v1 (só o código), enfileirado junto, com o mesmo guard e a mesma validade;
  - passo 1 pulado se o pedido não tiver código;
  - intervalo mínimo de 30 s → 5 s (2/min e 40/dia mantidos).

  Funções idênticas ao repositório. Testes 60/60.
- **Capacidade com 2 mensagens por cliente:** o limite de 40/dia cobre **~20 clientes/dia**. Subir para 60–80 conforme a saúde do número.

Texto final do passo 1:

```
Oi, {nome}! Vi que você gerou o Pix do *{produto}* e ele ainda está ativo por alguns minutos.

Para concluir, copie o código que vou mandar logo abaixo e cole no app do seu banco, em *Pix Copia e Cola*.

Se tiver qualquer dúvida, é só responder aqui.
```
```
{código Pix}
```
