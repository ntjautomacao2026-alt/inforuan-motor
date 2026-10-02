# Leona — o que a plataforma permite (análise em modo leitura)

> Fonte: MCP do Leona de **outra operação** (conta não relacionada ao INFORUAN), usado **somente para ler** a lista de ferramentas e os esquemas de blocos. Nada foi enviado, criado ou alterado, e nenhum dado de cliente foi lido.
> A implementação será feita numa **conta nova do Leona**, com número novo e conexão oficial da Meta.
> Complementa os prints enviados (MCP remoto com token Bearer; área "Webhooks de entrada").

## 1. Resultado por requisito

| Requisito | Pelo MCP | Dentro de um fluxo do Leona | Conclusão |
|---|---|---|---|
| Enviar mensagem | ❌ Nenhuma ferramenta | ✅ Bloco "Mensagem" | Só **dentro** de fluxo |
| Enviar template oficial | ❌ Nenhuma ferramenta | ✅ Bloco "Template" (HSM aprovado, variáveis, botões, saída `delivery_failed`) | Só **dentro** de fluxo |
| Localizar contato por telefone | ✅ `list_customers(search=telefone)` | ✅ variáveis `{customer.*}` | Possível |
| Criar contato | ✅ `create_customer` (telefone E.164 único) | — | Possível |
| **Iniciar fluxo** | ❌ **Nenhuma ferramenta** | ✅ "Conexão de fluxo" (um fluxo chama outro) | **Não há disparo externo pelo MCP** → depende de "Webhooks de entrada" |
| Consultar conversa / mensagens | ❌ Nenhuma ferramenta (`start_customer_chat` só abre o chat, sem enviar nem ler) | `{last_message}` no fluxo | **Não há leitura de histórico** |
| Listar conexões | ✅ `list_connections` | — | Possível |
| Status de entrega (entregue/lido) | ❌ Nenhuma ferramenta | ⚠️ Só a saída `template_delivery_failed` do bloco Template | **Não há status de entregue ou lido** |
| Receber mensagens no n8n | ❌ Nenhum webhook de saída no MCP | ✅ Bloco "Integração HTTP" (POST com `{customer.*}`, `{last_message}`; mapeia a resposta para campos do contato; saídas sucesso/falha) | Possível **por fluxo**, se um fluxo for disparado a cada mensagem recebida |
| Transferir para a inbox humana | ❌ Nenhuma ferramenta | ✅ "Controlador de chat" (Aguardando / Atendimento / Resolvidos), "Departamento", "Agente IA" (desativar), "Notificação" (alerta à equipe) | Só **dentro** de fluxo |

**Síntese**: o MCP do Leona é uma API de **construção de fluxos e administração de CRM**, não de mensageria. Tudo que envia, transfere ou reage acontece **dentro de fluxos**. A peça que falta para o n8n "mandar enviar" é um **gatilho externo de fluxo**. O candidato é "Webhooks de entrada", ainda não confirmado.

## 2. Arquitetura que funciona **se** "Webhooks de entrada" disparar fluxo

```
SAÍDA (n8n → cliente)
n8n WF-02 Dispatcher ──POST──► Leona "Webhook de entrada" (mapeia telefone + variáveis)
                                  └─► Fluxo "Régua Pix — passo N"
                                        └─► Bloco Template (HSM aprovado, variáveis mapeadas)
                                              ├─ entregue à Meta ──► Integração HTTP → n8n (log "aceito")
                                              └─ delivery_failed ──► Integração HTTP → n8n (log "falha")

ENTRADA (cliente → IA)
Mensagem recebida ─► Fluxo "Atendimento" (gatilho: qualquer mensagem)
   └─► Integração HTTP POST n8n WF-04 {telefone, customer.id, last_message}
         ← resposta {reply, action}  (mapeada para campos do contato)
   └─► Condição action:
         "reply"   → Mensagem "{customer.ia_resposta}" → Aguarda resposta → volta à Integração
         "handoff" → Controlador de chat "Aguardando" + Departamento "Atendimento"
                     + Notificação para a equipe (9h–20h) ou mensagem de fila (fora do horário)
```

- **O estado fica no Supabase.** O Leona só recebe a ordem de envio e devolve o resultado. Idempotência, guard de pagamento e holdout ficam no n8n + Supabase, **antes** da chamada ao Leona.
- Status disponível: **aceito/enviado** e **falhou**. Não há entregue nem lido. As métricas usam "enviado" como exposição.

## 3. O que preciso confirmar nos prints do formulário "Criar webhook" (Webhooks de entrada)

1. **Dispara um fluxo específico?** (escolha do fluxo no formulário)
2. **Escolhe a conexão (número) de envio?**
3. **Mapeamento**: aceita telefone (E.164) e campos livres (produto, código Pix, link, id do pedido) que viram variáveis no fluxo e no template?
4. **Contato inexistente**: cria automaticamente ou falha?
5. **Autenticação**: token no header, na URL ou nenhuma?
6. **Resposta**: devolve id do contato, chat ou execução? Síncrona?
7. **Conflito**: o que acontece se o contato já estiver em outro fluxo ou com o Agente IA como dono da conversa?
8. **Limites** de requisição por minuto.

E, fora do formulário:
9. **Gatilho "qualquer mensagem recebida"** para um fluxo (necessário para a IA)?
10. **Timeout do bloco Integração HTTP** (a IA leva de 3 a 8 s para responder).

## 4. Se "Webhooks de entrada" não disparar fluxo (alternativas, decidir antes de implementar)

| # | Alternativa | Prós | Contras |
|---|---|---|---|
| 1 | **Envio direto pela Cloud API da Meta a partir do n8n**, com o número no **WABA próprio do INFORUAN** (usuário de sistema) e o Leona só como inbox das respostas | Controle total; status entregue/lido disponíveis via webhook da Meta **se** o app do INFORUAN assinar o WABA | Mensagens enviadas fora do Leona podem **não aparecer no histórico da inbox**; exige verificar se o Leona permite um WABA próprio junto (coexistência de apps) |
| 2 | **Fluxo do Leona acionado por etiqueta ou campo** (se houver gatilho "etiqueta adicionada"): o n8n cria/atualiza o contato via MCP com uma etiqueta, e o fluxo dispara | Usa só recursos do Leona | Depende de existir esse gatilho; o MCP só aceita etiquetas no cadastro (`create_customer`), não em contato existente |
| 3 | **Trocar o canal por um BSP oficial com API completa** e inbox própria | API de envio, status e handoff completos | Migração e custo; atrasa a sexta |
| — | Evolution API | — | **Fora** por decisão |

**Recomendação**: validar o item 3 primeiro. Se "Webhooks de entrada" disparar fluxo com mapeamento de variáveis, a arquitetura da seção 2 atende os 6 itens de sexta sem alternativas.
