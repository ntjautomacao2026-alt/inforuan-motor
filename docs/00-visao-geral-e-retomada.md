# INFORUAN — Visão geral e ponto de retomada

> **Comece por aqui sempre que voltar ao projeto.**
> Atualizado em 05/10/2026. **Staging temporário no ar**, tudo que fala com cliente continua desligado.

## Status em 05/10/2026

- ✅ **Staging temporário** do n8n implantado na VPS compartilhada (KVM 2), fora do EasyPanel, em `/opt/inforuan-staging` (doc `12`). Ele fica nessa VPS por 2 a 3 dias, até a VPS exclusiva.
- ✅ Acesso somente por **túnel SSH** (`127.0.0.1:5679`), com chave dedicada `inforuan-staging-claude`. A chave temporária da implantação foi removida.
- ✅ Conferência só de leitura aprovada: 0 reinícios, limites e redes corretos, porta fechada para fora, backups e restauração testados, outros projetos intactos.
- ✅ **4 workflows importados e INATIVOS** (IR-03, IR-05, IR-06, IR-08). **0 credenciais.** IR-04 e IR-07 não foram importados.
- ✅ **Banco interno do n8n migrado para PostgreSQL 17.11** (doc `14`; resultado no doc `12`). Contagens idênticas, backup novo testado, outros projetos intactos. O volume do PG16 fica guardado por 48 h.
- ✅ **Etapa 2 aplicada no Supabase (05/10):** migração 0007 (modo **só internos** como padrão + envio simulado pausado) e 0008 (`pg_cron` com 3 jobs: tick a cada 30 s, handoffs + vigia a cada 5 min, retenção diária). Doc `15`.
- ❌ Sem webhook, sem Edge Function, sem `pg_net`, sem WhatsApp, sem telefones internos cadastrados, régua inativa, sem mensagens.

---

## 1. Objetivo final

Estamos construindo um **motor reutilizável de monetização para infoprodutos**, começando pelos produtos do Ruan (Finanças 40+ e Atualiza 40+).

Na primeira fase, ele vai:
- **recuperar Pix não pago** com mensagens no WhatsApp;
- **parar as cobranças na hora** em que o cliente paga;
- **orientar o cliente depois da compra** (como acessar o produto);
- **responder dúvidas básicas com IA**, só com informações aprovadas;
- **passar para uma pessoa** os casos que a IA não deve resolver.

Depois, o mesmo motor vai ajudar a **aumentar o ticket médio (AOV) e o valor de cada cliente ao longo do tempo (LTV)**, com upsell, cross-sell e recompra.

---

## 2. Arquitetura aprovada

```
 GGCheckout (vendas)
      │  avisa: Pix gerado, pago, expirado…
      ▼
 Edge Functions do Supabase  ── recebem os avisos, conferem a senha e guardam
      │
      ▼
 Supabase  ── FONTE OFICIAL: dados, regras, filas, controle de quem já pagou
      │
      ▼
 n8n self-hosted (VPS própria do INFORUAN)  ── executa: envia mensagens, chama a IA, avisa a equipe
      │
      ▼
 Provedor de WhatsApp  ── (AINDA NÃO ESCOLHIDO)
      │
      ▼
 Atendimento humano  ── casos transferidos (horário: 9h–20h)
```

**Regras de arquitetura:**
- O **Supabase é o banco operacional**: todos os dados e regras do motor ficam nele.
- O **n8n vai rodar numa VPS exclusiva do INFORUAN** (Hostinger).
- O **PostgreSQL da VPS serve só para o funcionamento interno do n8n**, e não guarda dados do motor.
- O n8n **só conversa com o Supabase por uma "porta" restrita** (o schema `api`). Ele não lê as tabelas diretamente.
- **Não usaremos n8n Cloud** em produção.
- **Não usaremos Leona.**
- **Não reutilizaremos** infraestrutura, números, credenciais, dados ou workflows de outras operações. O projeto é da **ntjautomacao** e do **Ruan**.
- O **provedor de WhatsApp ainda está pendente**.
- **Nenhuma integração real será ativada antes de a VPS estar pronta.**

---

## 3. O que já foi concluído

**Diagnóstico e negócio**
- ✅ Pesquisa da GGCheckout: quais avisos ela envia, o que a API permite e os limites dela.
- ✅ Diagnóstico da conta: vendas, ticket, Pix não pago (~17% dos pedidos), tempo de pagamento (o Pix vale 15 minutos) e order bumps (37–45% de adesão nos kits completos).
- ✅ Matriz comercial e inventário de todos os conteúdos das pastas do Drive.
- ⚠️ Achados que pedem ação do Ruan, fora do motor:
  - **5 clientes** compraram bumps que não têm arquivo na pasta: "Limpar Nome", "Negociar Dívidas" e "Pix Sem Golpe".
  - O checkout "É Golpe ou Não É?" está publicado com a pasta vazia, sem vendas até agora.

**Banco de dados (Supabase do INFORUAN, projeto `bsmuouivezjnfrcnamky`)**
- ✅ Projeto novo, separado de qualquer outra operação.
- ✅ Migrações **0001 a 0009 aplicadas**, mais a configuração inicial.
- ✅ **26 tabelas**, todas protegidas (RLS ligado, nenhum acesso público).
- ✅ Regras do motor dentro do banco: pagamento interrompe a régua, nada duplicado, limites de envio, pausa automática, transferência para humano, registro de tudo.
- ✅ **Porta restrita para o n8n** (schema `api`, com 10 funções).
- ✅ Usuário **`n8n_engine`**: **login liberado em 05/10** (senha só no Keychain do Mac; no banco, só cifrada), pelo pooler com TLS verificado. **Sem acesso direto às tabelas**: só pode usar a porta restrita (testado: 10 de 10 bloqueios).
- ✅ **Grupo de controle em 10%**, para medir quanto a régua realmente recupera.
- ✅ **Régua desligada.**
- ✅ Limpeza automática de dados brutos após 30 dias, pronta mas ainda não agendada.

**Qualidade e segurança**
- ✅ **28 testes automáticos passando.**
- ✅ **Auditoria de segurança do Supabase sem nenhum erro ou aviso**, só avisos informativos esperados.
- ✅ Código no GitHub (`ntjautomacao2026-alt/inforuan-motor`, privado), commits como `ntjautomacao`.
- ✅ Último commit antes deste documento: **`82c1fcb68ed4d654f0b60dc5821e51fa744ed218`**.

**Documentos já produzidos** (pasta `docs/`)

| Documento | Assunto |
|---|---|
| `01` | Arquitetura completa |
| `02` | GGCheckout |
| `03` | Diagnóstico da conta |
| `04` | Escopo do MVP |
| `05` | Matriz comercial |
| `06` | Propostas aprovadas: webhook, teste, grupo de controle |
| `07` | Checklist da base de conhecimento para o Ruan |
| `08` | Leona (descartado) |
| `09` | Camada de envio |
| `10` | Infraestrutura da VPS e limites do Supabase |
| `11` | Modo de execução no Claude (sessões, papéis, Gate de QA) |
| `12` | Staging temporário implantado: estado atual, conferência e pendências |
| `13` | Auditoria só de leitura da VPS compartilhada |
| `14` | Roteiro da migração do PostgreSQL do n8n para a versão 17 (executado em 05/10) |
| `15` | Etapa 2: modo só internos, envio simulado e `pg_cron` (aplicado em 05/10) |
| `16` | Etapa 3: login do `n8n_engine` (Parte A concluída em 05/10) e credencial no n8n (Parte B pendente) |
| `17` | Etapa 4: workflows só pela `api` (preparado no repositório; importação depois de 07/10) |
| `18` | Etapa 7: Edge Function `gg-webhook` (preparada e testada localmente; não publicada) |
| `19` | Provedor de WhatsApp: comparação, custos e recomendação (decisão pendente) |

---

## 4. O que NÃO foi ativado

- ❌ **Nenhum cliente recebeu mensagem.**
- ❌ **Nenhuma régua está ativa.**
- ❌ **Nenhum webhook foi criado na GGCheckout.**
- ❌ **Nenhuma Edge Function foi publicada.**
- ❌ **Nenhum workflow está ativo.** No staging há 4 workflows importados, todos inativos e sem credenciais. O n8n Cloud não é usado.
- ❌ **Nenhum provedor de WhatsApp foi conectado.**
- ⚙️ **`pg_cron` instalado** (0008): o banco processa a inbox, a régua e os handoffs sozinho. Com o modo **só internos**, a lista de internos vazia, a régua inativa e a instância simulada pausada, isso não gera nenhuma mensagem. **`pg_net` não está instalado**: o banco não faz chamadas de rede.
- ❌ **Nenhuma pasta, produto ou checkout existente foi alterado.** A única criação na GGCheckout foi um **checkout de teste não publicado** (R$ 5, marcado `internal_test`), autorizado para o teste ponta a ponta.
- ✅ **Os compradores atuais não perderam acesso a nada.**

---

## 5. Decisões pendentes

1. **VPS exclusiva:** contratação e configuração (proposta: Hostinger KVM 2, em São Paulo). Até lá, o staging roda temporariamente na VPS compartilhada.
2. **Domínio e subdomínios** da ntj.
3. **Provedor oficial de WhatsApp.**
4. **Supabase Free ou Pro.** Hoje o Free atende o MVP, com retenção de dados, backup diário próprio e sinal de vida. Os gatilhos para trocar estão no doc `10`.
5. **Aprovação final dos textos das mensagens** (templates).
6. **Base de conhecimento** a ser fornecida pelo Ruan (checklist no doc `07`).
7. **Quando separar entregáveis e ofertas** (pastas novas, sem tirar nada de quem já comprou).
8. **Quando ativar upsell e cross-sell.**

---

## 6. Roadmap Crawl → Walk → Run

### 🐢 Crawl — colocar o MVP seguro no ar
- [ ] Provisionar a VPS exclusiva. *(staging temporário na VPS compartilhada: ✅)*
- [x] Instalar o n8n e o banco interno dele (staging temporário).
- [x] Migrar o banco interno do n8n para PostgreSQL 17 (doc `14`).
- [x] Modo só internos + envio simulado + `pg_cron` no Supabase (doc `15`).
- [ ] Conectar o n8n ao Supabase (pela porta restrita).
- [ ] Escolher e conectar o WhatsApp.
- [ ] Publicar a Edge Function da GGCheckout. *(código e testes prontos, doc `18`)*
- [x] Importar os workflows **inativos** (4 antigos, ainda com service_role).
- [x] Refazer os workflows para `api.*` (IR-05, IR-06, IR-08; IR-03/IR-07 no `pg_cron`). Preparado no repositório (doc `17`); importação depois de 07/10.
- [ ] Testar de ponta a ponta com um contato interno.
- [ ] Criar o webhook da GGCheckout.
- [ ] Ativar a recuperação de Pix **aos poucos**.
- [ ] Confirmar que o pagamento interrompe as mensagens.
- [ ] Ativar pós-compra, IA limitada e transferência para humano.
- [ ] Acompanhar erros e métricas.

### 🚶 Walk — otimizar conversão e operação
- [ ] Consolidar a base de conhecimento.
- [ ] Testar mensagens e horários.
- [ ] Medir tratado versus controle.
- [ ] Melhorar o painel de acompanhamento.
- [ ] Estruturar o suporte.
- [ ] Separar os entregáveis novos sem retirar acesso dos compradores antigos.
- [ ] Testar o upsell nativo da GGCheckout.
- [ ] Melhorar o acompanhamento pós-compra.

### 🏃 Run — motor reutilizável de monetização
- [ ] Esteiras configuráveis por produto.
- [ ] Upsell, cross-sell, recompra e winback.
- [ ] Novos produtores, cada um isolado.
- [ ] Experimentação contínua.
- [ ] Medição do ganho real (incremental) de cada ação.
- [ ] Cálculo de AOV, LTV, margem e ROAS.
- [ ] Múltiplos canais.
- [ ] Ajuste das regras sem precisar mexer em código.

---

## 7. Próxima ação ao retomar

> **Depois de 07/10 18:15 UTC, com autorização:** decidir a remoção do volume do PG16 → CA do Supabase no n8n (`NODE_EXTRA_CA_CERTS`) → credencial Postgres do `n8n_engine` (doc `16`, Parte B) → trocar os 4 workflows antigos pelos 3 novos, inativos (doc `17`). **Sem tocar no n8n até lá:** publicar a Edge Function `gg-webhook` (doc `18`, fases A–D, com autorização) e definir o provedor de WhatsApp. O webhook na GGCheckout (fase E) tem autorização própria.

---

## 8. Como me atualizar em 2 minutos

- **Onde estamos:** o banco do motor está pronto e protegido no Supabase. O n8n roda num staging temporário, acessível só por túnel SSH, com 4 workflows inativos e sem credenciais.
- **O que está pronto:** diagnóstico da GGCheckout, matriz comercial, banco com 26 tabelas e regras testadas (28 testes), porta restrita para o n8n, grupo de controle de 10%, workflows salvos no GitHub e documentação.
- **O que está desligado:** **tudo que fala com cliente.** Régua desligada, sem webhook, sem Edge Function, sem workflow ativo, sem WhatsApp e sem agendamentos no banco. Ninguém recebeu mensagem.
- **Próximo passo:** publicar a Edge Function (doc `18`) e escolher o provedor de WhatsApp. Depois de 07/10 18:15 UTC: Parte B da Etapa 3 + importação da Etapa 4 (docs `16` e `17`).
- **Decisões que dependem de você:** VPS, domínio, provedor de WhatsApp, Supabase Free ou Pro, aprovação dos textos, base de conhecimento do Ruan, e quando separar entregáveis e ativar upsell e cross-sell.
