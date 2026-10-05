# Auditoria da VPS compartilhada (05/10/2026)

> ⚠️ **A seção 3 (plano via EasyPanel) está OBSOLETA.** A instalação foi feita fora do EasyPanel, com Docker Compose direto no servidor. O estado vigente está em [`12-staging-temporario-implantado.md`](12-staging-temporario-implantado.md), e a configuração válida é `infra/staging/docker-compose.temporary.yml`. As seções 1 (auditoria) e 2 (riscos) continuam válidas como retrato da VPS.

> 05/10/2026 · VPS `srv946244` (Hostinger KVM 2; IP no painel da Hostinger) · auditoria **somente leitura** (API da Hostinger + SSH com chave dedicada `inforuan-staging-claude`).
> **Nada foi instalado, reiniciado ou alterado.** Única escrita feita: instalação da chave SSH do INFORUAN (ver §1.6).

## 1. Auditoria

### 1.1 Capacidade
| Recurso | Total | Uso típico | Pico (7 dias) | Folga |
|---|---|---|---|---|
| CPU | 2 vCPU | 2–10% | 19% | Ampla. *Steal* de 3–8% (vizinhos no host físico) |
| Memória | 7,9 GB | 3,6 GB usados (+3,3 GB de cache) | 4,7 GB | **~4,2 GB disponíveis** |
| Memória comprometida | — | 71–75% | — | Margem menor do que parece |
| **Swap** | **nenhum** | — | — | ⚠️ Sem rede de segurança contra falta de memória |
| Disco | 96 GB | 15 GB (15%) | 17 GB | 82 GB livres |

### 1.2 O que roda hoje (EasyPanel / Docker Swarm, 12 serviços)
| Projeto | Serviços | Memória agora |
|---|---|---|
| **`king`** | `king_os`, `n8n` 2.35.4, `n8n-db` (Postgres 17), `n8n-runner` | **~2,7 GB** (n8n 1,7 GB + banco 0,9 GB) |
| `n8n` | `n8n` 1.123.20, `postgres`, `redis` | ~0,5 GB |
| `evoltuionapi` | Evolution API v2.3.7, Postgres, Redis | ~0,4 GB |
| sistema | EasyPanel (`latest`), Traefik 3.6.7 | ~0,2 GB |

- **Nenhum serviço tem limite de CPU ou memória.** Qualquer um pode consumir a máquina inteira.
- Há 2 containers `n8n` antigos parados ("Dead") e 1 `king_os` antigo encerrado (resíduos).

### 1.3 Rede, portas e proxy
- **Proxy:** Traefik do EasyPanel nas portas 80/443, com rotas geradas pelo EasyPanel.
- **Domínios:** um domínio próprio da outra operação e subdomínios `*.h8xmsm.easypanel.host` (king-os, king-n8n, n8n-n8n, evolution, painel, traefik).
- **Portas abertas para a internet:** 22 (SSH), 80, 443, **3000 (painel do EasyPanel em HTTP, sem TLS)**, **2377 e 7946 (gerência do Docker Swarm)**.
- **Firewall:** `ufw` **inativo**, iptables `INPUT ACCEPT` e **nenhum firewall na Hostinger**.
- **Redes:** cada projeto tem sua rede, mas **todos os serviços, inclusive os bancos, também estão na rede compartilhada `easypanel`**. Um container de um projeto consegue alcançar o banco de outro pelo nome do serviço; o que os separa é só a senha.

### 1.4 Webhook global
- Evolution API: `WEBHOOK_GLOBAL_ENABLED=false`, URL vazia. ✅ Nenhum vazamento de eventos para outros sistemas por webhook global.

### 1.5 Backups
- Hostinger: **backup diário automático da VM inteira**, guardado no Brasil (há 4 restaurações disponíveis: 22/09, 29/09, 04/10, 05/10; ~30 min para restaurar).
- **Nenhum snapshot manual.** Nenhum dump de banco agendado no servidor.
- ⚠️ O backup da Hostinger **restaura a VM inteira**. Não dá para voltar só o INFORUAN sem voltar junto os outros projetos.

### 1.6 Acesso concedido ao INFORUAN
- Chave SSH `inforuan-staging-claude` (ED25519, `SHA256:SRCSQquZ1Dij…LAAM`) em `/root/.ssh/authorized_keys`.
- Efeito colateral: a chave temporária que a Hostinger gera para o Console da Web, que vencia em minutos, saiu junto ao corrigir uma linha grudada. A Hostinger recria essa chave ao abrir o console.
- Chave pública também cadastrada na conta Hostinger (id 594259, sem efeito no servidor).
- **Para revogar:** apagar a linha `inforuan-staging-claude` de `/root/.ssh/authorized_keys`.

---

## 2. Riscos

| # | Risco | Gravidade | Mitigação no plano |
|---|---|---|---|
| R1 | **A VPS hospeda projetos de outra operação** (`king`, `n8n`, `evoltuionapi`), o que contraria a regra de isolamento | Alta (governança) | Uso **temporário autorizado** (2–3 dias), sem tocar nos projetos existentes, com migração planejada |
| R2 | **Sem swap e sem limites nos serviços existentes**: um pico de memória de qualquer projeto pode acionar o *OOM killer* e derrubar serviços de qualquer projeto | Média | Limites rígidos no INFORUAN (protegem os outros dele). Swap de 2 GB recomendado (mexe no host: **decisão sua**) |
| R3 | **Painel do EasyPanel em HTTP na porta 3000** e **portas do Swarm (2377/7946) abertas**, sem firewall | Alta (já existe hoje, independe do INFORUAN) | **Não mexo agora** (é infraestrutura das outras operações). Recomendo tratar à parte |
| R4 | **Rede `easypanel` compartilhada**: bancos de todos os projetos se alcançam | Média | Postgres do INFORUAN **só numa rede interna própria**, fora da `easypanel` (verificado no Gate de QA). Senhas únicas e longas |
| R5 | **Administração compartilhada**: quem acessa o EasyPanel ou o root vê todos os projetos, inclusive as variáveis do INFORUAN | Média | Staging sem dados de clientes reais até o Gate de QA. Segredos trocados na migração para a VPS definitiva |
| R6 | Backup da Hostinger é da VM inteira | Média | Dump próprio diário do Postgres do n8n + export dos workflows |
| R7 | Proxy (Traefik) compartilhado | Baixa | Só adicionamos uma rota pelo próprio EasyPanel. Nada é editado à mão |
| R8 | Sem domínio próprio (Cloudflare Access indisponível) | Média | Subdomínio `*.easypanel.host`, n8n com senha forte + **MFA**, webhook de "acordar" com cabeçalho secreto |

**Capacidade:** cabe. O INFORUAN staging fica com teto de **~2 GB** de RAM (uso típico de ~0,7 GB) contra ~4,2 GB disponíveis.

---

## 3. ~~Plano exato de instalação~~ — OBSOLETO (substituído pelo doc 12)

### 3.1 Antes
1. **Snapshot manual** da VPS na Hostinger, ponto de volta antes da instalação. Requer autorização.
2. Confirmar R1 (uso temporário desta VPS) e a forma de execução (§3.5).

### 3.2 Projeto `inforuan-staging` no EasyPanel: um serviço do tipo **Compose**
~~Arquivo `infra/staging/docker-compose.yml`~~ → movido para `infra/_historico/OBSOLETO-docker-compose.easypanel.yml.txt`.

| Serviço | Imagem (fixada) | Redes | Limite | Volume |
|---|---|---|---|---|
| `n8n` | `n8nio/n8n:2.35.4` | `inforuan_internal` + `easypanel` (só para o Traefik) | 1 CPU · 1,5 GB | `inforuan_n8n_data` |
| `n8n-runner` | `n8nio/runners:2.35.4` | `inforuan_internal` | 0,5 CPU · 512 MB | — |
| `postgres` | `postgres:16-alpine` | **somente `inforuan_internal`** | 0,5 CPU · 512 MB | `inforuan_pg_data` |
| `pg-backup` | `prodrigestivill/postgres-backup-local:16` | `inforuan_internal` | 0,25 CPU · 256 MB | `inforuan_pg_backups` (7 diários + 4 semanais) |
| `redis` | — | — | — | **não criado** (só com queue mode) |

- Rede `inforuan_internal` com `internal: true`: sem saída para a internet e invisível aos outros projetos.
- **Domínio:** `inforuan-n8n.h8xmsm.easypanel.host` → `n8n:5678`, com HTTPS automático do Traefik. Nenhum DNS alterado.
- **Segredos exclusivos** (gerados aleatoriamente, 32+ caracteres): senha do Postgres, `N8N_ENCRYPTION_KEY`, token do runner. Eles ficam só nas variáveis do EasyPanel e no gerenciador de senhas da ntj, **nunca no Git**.

### 3.3 Depois de subir (tudo inativo)
1. Criar a conta *owner* do n8n com MFA.
2. Ativar o MCP da instância (para eu operar) e conectar como `n8n-staging-inforuan`.
3. Habilitar o login do `n8n_engine` no Supabase com senha exclusiva → credencial Postgres no n8n (só o schema `api`).
4. Importar os workflows **inativos**.

### 3.4 Gate de QA (antes de qualquer tráfego real)
- [ ] `postgres` **não** está na rede `easypanel` (`docker inspect`)
- [ ] Limites de CPU e memória aplicados nos 4 containers
- [ ] Nenhum serviço do Me Crédito/king reiniciado (comparar *uptime* antes e depois)
- [ ] Memória livre da VPS acima de 2,5 GB após 1 h
- [ ] Backup do Postgres gerado e **restaurado com sucesso** num banco de teste
- [ ] `n8n_engine` consegue só `api.*` (teste negativo em tabela)
- [ ] Teste ponta a ponta com **contato interno** e checkout de teste (R$ 5), com o pagamento interrompendo a régua
- [ ] Sua aprovação explícita → só então webhook da GGCheckout e envio real

### 3.5 Forma de execução (decisão sua)
- **A — Você no painel do EasyPanel**, com o meu passo a passo e o arquivo pronto (recomendado: ninguém além de você opera o painel compartilhado).
- **B — Eu pela API do EasyPanel**, que exige um token que dá controle de **todos** os projetos do painel, inclusive os `king`.

### 3.6 Portabilidade e migração para a VPS definitiva
1. Mesmo `infra/staging/docker-compose.temporary.yml` (ajustado para a VPS definitiva) e mesmas variáveis (inclusive a **mesma `N8N_ENCRYPTION_KEY`**, que mantém as credenciais legíveis).
2. `pg_dump` do Postgres do n8n → restaurar na VPS nova → subir o compose.
3. Atualizar a URL do "acordar" no Supabase e o MCP.
4. Validar → desligar o staging → **apagar o projeto `inforuan-staging` e a chave SSH** desta VPS.

**Inventário de volumes:** `inforuan_n8n_data` (binários temporários e configuração local do n8n), `inforuan_pg_data` (estado do n8n: workflows, credenciais cifradas, execuções) e `inforuan_pg_backups` (dumps diários).
