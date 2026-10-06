# WhatsApp via Evolution própria (sessão Web, sem API oficial)

> **Status: Fases 1 e 2 CONCLUÍDAS em 05–06/10/2026 (resultado na seção 6). Fase 3 pendente** (depois de 07/10 18:15 UTC, com autorização).
> Plano original: Decisão do usuário em 05/10/2026: começar pelo WhatsApp Web (QR) com uma **Evolution própria do INFORUAN** e um **número novo e exclusivo**, que já existe. A API oficial (doc `19`) fica como evolução futura.
> **Risco aceito:** não é oficial. O número pode ser bloqueado, sobretudo ao escrever para quem nunca falou com ele. As mitigações estão na seção 4.

## 1. Arquitetura

```
WhatsApp (número do INFORUAN)
   ▲  sessão Web (Baileys)
   │
Evolution INFORUAN (container novo, v2.3.7)  ── sem porta publicada; redes backend (interna) + egress (saída)
   │  webhook GLOBAL (fixo no container)       ── desligado até a Fase 3
   ▼
n8n INFORUAN (rede interna) ── IR-02 ──▶ api.ingest_evolution_event ──▶ motor (Supabase)
n8n IR-04 ──▶ api.claim_outbound ──▶ Evolution sendText (rede interna, token SÓ da instância) ──▶ api.mark_outbound_result
n8n IR-07 ──▶ estado da conexão ──▶ api.set_instance_state (pausa automática se cair)
```

- **Nenhum endpoint público novo.** Os eventos da Evolution vão ao n8n pela rede interna do Docker; o envio também é interno.
- **Isolamento:** containers, rede, banco, volume e chaves exclusivos do INFORUAN. **Nunca** usar o projeto `evoltuionapi` da outra operação nem a chave global dele. Usar a mesma imagem v2.3.7 já baixada não compartilha nada.
- **Por que v2.3.7:** é a última estável e inclui a correção da falha crítica de leitura de arquivos que existia até a v2.3.2. A 2.4.0 (em teste) passa a exigir ativação em servidor de licença externo.
- **Por que webhook global:** há um bug conhecido em que o webhook por instância se perde ao reiniciar. Como esta Evolution só tem a instância do INFORUAN, o global é seguro.

## 2. Fases

### Fase 1 — subir a Evolution (VPS; não toca no n8n nem nos outros projetos)

- **Cópias de segurança e linha de base:** copiar o compose e o `.env` e registrar a linha de base dos outros serviços, como na migração do PG17.
- **Segredos novos gerados no servidor**, acrescentados ao `.env` (permissão 600) e **nunca exibidos**: senha do Postgres da Evolution, chave global da Evolution e token da instância.
- **Dois serviços novos no compose:**

| Serviço | Imagem | Redes | Limite | Volume |
|---|---|---|---|---|
| `evolution` | `evoapicloud/evolution-api:v2.3.7` | backend + egress | 768 MB / 0,6 CPU | `inforuan-staging-evolution-instances` |
| `evolution-postgres` | `postgres:17-alpine` | **só backend** | 256 MB / 0,2 CPU | `inforuan-staging-evolution-pg` |

- **Configuração principal da Evolution:**
  - **Banco:** PostgreSQL próprio. O cache Redis fica desligado; só cache local.
  - **Mínimo de dados pessoais:** `DATABASE_SAVE_DATA_NEW_MESSAGE`, `_MESSAGE_UPDATE`, `_CONTACTS`, `_CHATS`, `_LABELS` e `_HISTORIC` = **false**. A Evolution guarda só a sessão; mensagens e contatos ficam apenas no motor.
  - **Webhook:** `WEBHOOK_GLOBAL_ENABLED=false` até a Fase 3.
  - **Instância:** `DEL_INSTANCE=false`; nome do aparelho `INFORUAN`.
  - **Logs:** só erros e alertas, com rotação de 10 MB × 3.
- **Subir só os serviços novos:** `docker compose -p inforuan-staging up -d evolution-postgres evolution`. O n8n, o runner, o Postgres do n8n e o backup não são recriados.
- **Conferir:**
  - os 2 serviços novos `healthy`, sem porta publicada e nas redes certas;
  - os limites aplicados e a memória da VPS;
  - **os outros serviços intactos** (mesma hora de início, 0 reinícios);
  - as variáveis de ambiente realmente aplicadas: há relatos de versões que ignoram variáveis.

### Fase 2 — conectar o número (QR)

1. Criar a instância `inforuan-01` pela API, de dentro do servidor:
   - integração Baileys, com o token da instância vindo do `.env`;
   - ignorar grupos;
   - **sem sincronizar histórico**;
   - sem marcar mensagens como lidas e sem "sempre online".
2. Gerar o QR: o servidor devolve a imagem, que eu salvo no Mac e abro no painel ao lado, sem copiar o conteúdo para o chat.
3. **Você escaneia** com o celular do número do INFORUAN (WhatsApp → Aparelhos conectados → Conectar aparelho). O QR vale ~40 s; gero outro se expirar.
4. Conferir `connectionState = open`. Você me confirma **só os 4 últimos dígitos** do número conectado.

Depois disso o número fica conectado, mas **nada flui**: sem webhook, sem envio, nenhum dado gravado no motor.

### Fase 3 — ligar ao motor (junto com a Etapa 4, depois de 07/10 18:15 UTC)

- **0011:**
  - `provider_instances` `inforuan-01` (Evolution) **pausada**, com limites de aquecimento: 2/min, intervalo de 30 s, 40/dia;
  - `api.ingest_evolution_event($1::jsonb)`: confere a instância e remove o token;
  - no modo **só internos**, descarta mensagens de quem não é interno sem gravar nada pessoal (como na `gg-webhook`); os eventos de conexão e de status passam;
  - deduplicação e processamento imediato.
- **Workflows novos, todos inativos:**
  - IR-02 (webhook interno do n8n);
  - IR-04 (envio: reserva → conferência de pagamento na GGCheckout para recuperação → Evolution → resultado);
  - IR-07 (estado da conexão → pausa automática).
- **Credencial "Evolution INFORUAN"** criada no n8n com o **token da instância** (nunca a chave global), importada do `.env` no servidor, sem exibir.
- Ligar o webhook global apontando para o IR-02 (`http://n8n:5678/webhook/evo-<sufixo aleatório>`, só na rede interna) e recriar só o container da Evolution.

## 3. O que NÃO acontece

- Nenhuma mensagem é enviada. A instância nasce pausada, o motor está em modo só internos e a régua está desligada.
- Nada é publicado na internet. Nenhum serviço de outra operação é tocado.

## 4. Mitigações de banimento

- **Número exclusivo e aquecido:** uso normal por alguns dias antes de automatizar.
- **Limites baixos de início** (2/min, 40/dia) e subida gradual. O banco já impõe intervalo, teto e pausa automática por rajada de erros.
- **Só transacional:** quem gerou Pix ou comprou nos últimos 30 dias, ou quem escreveu. **Nunca disparo para a base:** é recusado pelo banco.
- **"PARAR"** para descadastro, cumprido na hora. Resposta do cliente pausa a régua. Handoff humano das 9h às 20h.
- **Mensagens curtas, personalizadas e sem link na primeira mensagem**, quando possível.

## 5. Reversão

- **Fase 1:** `docker compose -p inforuan-staging stop evolution evolution-postgres` e voltar o compose e o `.env` pela cópia. Os volumes ficam para análise e só são removidos com autorização.
- **Fase 2:** desconectar a instância (`logout`) ou, no celular, Aparelhos conectados → sair.
- **Fase 3:** desativar os workflows, pausar a instância (`provider_instances.paused = true`) e desligar o webhook global.

## Fontes

- Releases da Evolution API: https://github.com/evolution-foundation/evolution-api/releases
- Docker da Evolution (documentação oficial): https://docs.evolutionfoundation.com.br/en/evolution-api/install/docker
- Bug do webhook por instância perdido ao reiniciar: https://github.com/evolution-foundation/evolution-api/issues/2694
- Variáveis ignoradas em algumas imagens: https://github.com/EvolutionAPI/evolution-api/issues/1474

## 6. Resultado das Fases 1 e 2

| Verificação | Resultado |
|---|---|
| Containers | `inforuan-staging-evolution` (v2.3.7) e `inforuan-staging-evolution-postgres` (17-alpine) `healthy`, 0 reinícios |
| Limites e redes | 768 MB / 0,6 CPU e 256 MB / 0,2 CPU. Evolution em backend + egress; banco **só** no backend. **Nenhuma porta publicada** no host |
| Configuração aplicada | `DOCKER_ENV=true` (impede que o `.env` de exemplo da imagem sobrescreva o ambiente e evita imprimir a URL do banco no log). Nada de mensagens, contatos, chats ou histórico salvos. Telemetria, webhook global e integrações desligados |
| Ajuste durante a execução | `CORS_ORIGIN` de `http://localhost` para `*`: o valor restrito bloqueava chamadas sem cabeçalho de origem (teste de saúde e n8n). Sem porta publicada e com chave obrigatória, CORS não protege nada aqui. Só o container da Evolution foi recriado |
| Autenticação | Sem chave → 401. Segredos (`INFORUAN_EVO_*`, 40 caracteres) só no `.env` do servidor, nunca exibidos |
| Compose | Servidor = repositório (`infra/staging/docker-compose.temporary.yml`). Cópias antes da mudança em `/opt/inforuan-staging/evolution-setup/` |
| Outros projetos | **OUTROS-INTACTOS** (mesma hora de início e réplicas). Containers antigos do INFORUAN não recriados |
| Instância | `inforuan-01`, Baileys, token = o do `.env`. Ignora grupos, sem histórico, sem marcar como lida, sem "sempre online" |
| Conexão | O QR foi recusado pelo celular ("não é possível conectar novos dispositivos"). Conectou pelo **código de pareamento** (`?number=` após `logout` da sessão) em 06/10. Estado **`open`**; número conectado termina em **6278** (fixo, DDD 31) |
| Dados | Banco da Evolution: 0 mensagens, 0 contatos, 0 chats, 1 instância. Webhook desligado: **nada flui para o motor e nada sai** |

**Próximo:** aquecer o número com uso normal. A Fase 3 vem junto com a Etapa 4, depois de 07/10 18:15 UTC.

## 7. Fase 3: preparada no repositório (06/10/2026), NÃO aplicada nem importada

| Peça | Arquivo | O que faz |
|---|---|---|
| **0011** | `supabase/migrations/0011_whatsapp_evolution.sql` | `inforuan-01` no motor **inativa e pausada** (2/min, 30 s, 40/dia), para o vigia não alertar antes do IR-07. `api.ingest_evolution_event($1::jsonb)`: confere a instância, remove o token, aceita só `messages.upsert`, `send.message`, `messages.update` e `connection.update`, deduplica e processa na hora. **Só internos:** mensagens **e status** de não internos são descartados sem telefone nem texto (fica só a contagem `evo.ignored_internal_only`); conexão sempre passa |
| **IR-02** | `n8n/build.mjs` | Webhook **interno** `evo/<sufixo aleatório>` → `api.ingest_evolution_event`. Não guarda execuções |
| **IR-04** | `n8n/build.mjs` | Reserva 1 mensagem → só recuperação consulta o pagamento na GGCheckout (pagou → reconcilia e cancela) → `sendText` em `http://evolution:8080` com o **token da instância** → classifica → `api.mark_outbound_result`. Não guarda execuções |
| **IR-07** | `n8n/build.mjs` | Estado da conexão a cada 60 s → `api.set_instance_state` (pausa automática se cair) |
| **IR-08** | `n8n/build.mjs` | Estendido: pagos (2 h) + **reembolsados e chargebacks (30 dias)**, porque a GGCheckout não manda reembolso no webhook |

**Testes: 51/51.** Inclui a 0011 (5 cenários) e o SQL de cada nó do IR-02, IR-04 e IR-07 rodando como `n8n_engine`.

**Execução (depois de 07/10 18:15 UTC, cada passo com autorização):**
1. Aplicar a 0011.
2. Criar a credencial "Evolution INFORUAN (token da instância)" no n8n a partir do `.env` do servidor, sem exibir.
3. Importar o IR-02, IR-04 e IR-07 inativos, junto com a Etapa 4.
4. Ligar o webhook global da Evolution para `http://n8n:5678/webhook/evo/<sufixo>` (só o container da Evolution é recriado).
5. Testes internos.
6. **Só com autorização:** `provider_instances.active = true` e `unpause_instance('inforuan-01', …)`.

**A conferir no teste:** os nomes exatos de status no `messages.update` (o motor já mapeia `SERVER_ACK`, `DELIVERY_ACK`, `READ`, `PLAYED`, `ERROR`) e os valores de status da API da GGCheckout para reembolso e chargeback (`refunded` e `charged_back` assumidos).

## 8. Execução da Fase 3 (06/10/2026, autorizada ao antecipar a janela do PG16)

| Passo | Resultado |
|---|---|
| CA do Supabase no n8n | `NODE_EXTRA_CA_CERTS` + certificado montado só leitura. Só o n8n foi recriado. TLS até o pooler verificado de dentro do container. Outros intactos |
| Credencial Postgres (usuário, pelo túnel) | `INFORUAN Supabase (n8n_engine)` (id `NnDvALgmSD1vcvKm`). 1ª tentativa falhou com o campo de senha vazio (pooler: "Timeout … SCRAM final"); refeita, autenticou às 14:27:33 UTC. A opção "SSH Tunnel" da credencial fica **desligada** |
| Telefones internos (usuário, SQL Editor) | 2 números (finais 4236 e 7843), formato conferido |
| 0011 (MCP) | Aplicada. Funções idênticas ao repositório (`ingest_evolution_event` 2d46be56…, `evo_jid_phone` 5cb82489…). `inforuan-01` inativa e pausada (2/min, 30 s, 40/dia). `api` com 11 funções; `n8n_engine` executa só a de `api` |
| Credencial Evolution | Montada no servidor a partir do `.env` (token da instância), importada com `n8n import:credentials`, criptografada pelo n8n (id `nyL91EwaKwfgotMA`). Arquivo temporário apagado; token nunca exibido |
| Workflows | IR-02, IR-04 e IR-07 importados **inativos**, já ligados às credenciais. IR-04 ainda sem a credencial da GGCheckout. Os 4 antigos seguem inativos (arquivar depois) |
| Webhook global | Ligado para `http://n8n:5678/webhook/evo/<sufixo>`; URL só no `.env` e no `n8n/config.local.json`. Só 4 eventos (`MESSAGES_UPSERT`, `MESSAGES_UPDATE`, `SEND_MESSAGE`, `CONNECTION_UPDATE`); os outros 26 desligados explicitamente. Só a Evolution foi recriada; a sessão continuou `open`. Os 404 no log são esperados até o IR-02 ser ativado |
