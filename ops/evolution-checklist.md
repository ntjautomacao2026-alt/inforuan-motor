# Evolution — checklist da instância INFORUAN (servidor compartilhado, fase de 3–5 dias)

> Fazer **nesta ordem**. Nada de QR Code antes do passo 3.
> Não usar a API key global do servidor em nenhum lugar do n8n do INFORUAN.

## 1. Webhook global do servidor (bloqueante)
No servidor Evolution (variáveis de ambiente do container/serviço, arquivo `.env` ou `docker-compose.yml`), procurar:
- `WEBHOOK_GLOBAL_ENABLED`
- `WEBHOOK_GLOBAL_URL`
- `WEBHOOK_GLOBAL_WEBHOOK_BY_EVENTS`

| Situação | Ação |
|---|---|
| `WEBHOOK_GLOBAL_ENABLED=false` ou ausente | ✅ Seguir |
| `true` apontando para o n8n da outra operação | ❌ **Parar.** Opção A: desligar o global e configurar webhook por instância nas instâncias da outra operação (exige janela de manutenção da outra operação). Opção B: garantir que TODOS os workflows da outra operação que recebem esse webhook filtram `body.instance` pelas instâncias da outra operação e descartam o resto, e aceitar que os eventos do INFORUAN (com dados pessoais) vão chegar ao n8n da outra operação até a migração. **Recomendo a A.** |

Registrar aqui o resultado: `WEBHOOK_GLOBAL_ENABLED = ____` (data/hora, quem verificou).

## 2. Criar a instância
- Nome: `inforuan-01`
- Integração: `WHATSAPP-BAILEYS` (QR Code)
- Guardar o **token da instância** somente na credencial do n8n do INFORUAN (`Evolution INFORUAN (apikey da instância)`, tipo Header Auth, nome do header `apikey`).

## 3. Webhook da instância (só para o n8n do INFORUAN)
- URL: `https://<n8n-inforuan>/webhook/evo/<EVO_WEBHOOK_PATH_SUFFIX>`
- `webhookByEvents`: **false**
- `webhookBase64`: false
- Eventos: `MESSAGES_UPSERT`, `MESSAGES_UPDATE`, `SEND_MESSAGE`, `CONNECTION_UPDATE`
- Se a versão da Evolution aceitar `headers` no webhook da instância, adicionar um header secreto e trocar o nó "Webhook Evolution" para Header Auth (hoje a proteção é o sufixo aleatório no caminho + a checagem do nome da instância).

## 4. Coexistência + QR (primeiro teste técnico)
1. Conectar o número novo ao **Leona** pela coexistência oficial (WhatsApp Business no celular). **Nenhum fluxo e nenhum agente de IA ativos** na conta Leona do INFORUAN.
2. Só depois, ler o QR da `inforuan-01` com o WhatsApp Business do celular (aparelhos conectados).
3. Verificar:
   - [ ] a instância fica `open` por 30 min;
   - [ ] a coexistência continua ativa no Leona;
   - [ ] mensagem enviada pela Evolution aparece no celular (e no Leona);
   - [ ] mensagem recebida gera `MESSAGES_UPSERT` no n8n;
   - [ ] resposta digitada no celular gera eco `fromMe=true` (é o que ativa o modo humano).
4. Se a coexistência derrubar o QR (ou vice-versa): **parar** e reavaliar o transporte.

## 5. Migração de servidor (após 3–5 dias)
1. `paused=true` na instância (ou só desconectar: a pausa é automática).
2. Criar `inforuan-01` no servidor novo + webhook da instância (passo 3).
3. Ler o QR no servidor novo; trocar `EVOLUTION_BASE_URL` no `n8n/config.local.json`, regerar e reimportar IR-04/IR-07, e atualizar a credencial com o token novo.
4. Testar envio/recebimento com o telefone interno → despausar.
5. Apagar a instância do servidor antigo.
