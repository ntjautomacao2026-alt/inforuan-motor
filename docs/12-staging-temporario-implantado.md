# Staging temporário do INFORUAN — estado atual

> Implantado em 05/10/2026 na VPS compartilhada da Hostinger, exclusivamente para validação por 2–3 dias.
> Nenhum workflow, webhook, envio ou automação de cliente está ativo.

## O que foi criado

- Diretório exclusivo no servidor: `/opt/inforuan-staging`.
- Quatro containers próprios: n8n, task runner, PostgreSQL interno do n8n e backup do PostgreSQL.
- Duas redes próprias: uma interna para banco/runner e outra apenas para a saída do n8n.
- Três volumes próprios: estado do n8n, dados do PostgreSQL e backups.
- Credenciais aleatórias exclusivas, armazenadas somente no servidor com permissão restrita.
- Acesso SSH por chave dedicada `inforuan-staging-claude` (a chave temporária usada na implantação foi removida em 05/10; ver abaixo).

O ambiente não usa as redes dos projetos `king`, `n8n` ou `evoltuionapi` do EasyPanel.

## Acesso

O n8n está publicado somente em `127.0.0.1:5679` dentro da VPS. A porta 5679 não responde pela internet. O painel é acessado pelo Mac através de túnel SSH e abre localmente em:

`http://127.0.0.1:5679`

Não há domínio, DNS ou rota no Traefik/EasyPanel para este staging.

## Limites aplicados

| Serviço | Memória | CPU |
|---|---:|---:|
| n8n | 1 GB | 0,8 CPU |
| PostgreSQL interno | 768 MB | 0,5 CPU |
| task runner | 384 MB | 0,4 CPU |
| backup | 128 MB | 0,1 CPU |
| **Teto total** | **2,25 GB** | **1,8 CPU** |

Uso inicial observado: aproximadamente 357 MB de RAM no conjunto.

## Verificações concluídas

- n8n e PostgreSQL saudáveis, sem reinicializações.
- Cada container está somente nas redes previstas.
- Nenhum container do INFORUAN entrou na rede global `easypanel`.
- Banco, runner e backup não têm porta publicada.
- A porta 5679 recusou conexão externa e respondeu pelo túnel local.
- Serviços antigos mantiveram o mesmo tempo de atividade; nenhum foi reiniciado.
- Primeiro backup lógico criado com sucesso.
- Restauração comprovada em banco temporário: 126 tabelas restauradas.
- Banco temporário de teste removido após a validação.

## Estado funcional

- Regra de recuperação: desligada.
- Conta proprietária do n8n: criada.
- Workflows importados e confirmados como inativos:
  - `IR-03 Motor tick`;
  - `IR-05 Atendimento IA`;
  - `IR-06 Alertas Telegram`;
  - `IR-08 Reconciliacao GGCheckout`.
- `IR-04 Envio WhatsApp` e `IR-07 Saude e manutencao` não foram importados porque ainda contêm o adaptador provisório da Evolution. O provedor do INFORUAN continua pendente.
- Webhooks: ainda não criados/alterados.
- WhatsApp: provedor ainda pendente.
- Tráfego e contatos reais: não autorizados.
- Credenciais de Supabase, GGCheckout, IA e alertas: ainda não cadastradas no n8n.
- Backup lógico atualizado depois da criação da conta e da importação.
- Próxima ação: configurar e testar as credenciais, mantendo os workflows **inativos**.

### Pendência técnica antes da produção

O n8n 2.35.4 iniciou normalmente, mas informou que o PostgreSQL 16 recebe apenas suporte de compatibilidade. Planejar a migração do banco interno do n8n para PostgreSQL 17 antes de liberar tráfego real.

Roteiro proposto, **ainda não executado**: `docs/14-roteiro-migracao-postgres17.md`.

## Conferência de 05/10/2026 (~17:40 UTC, somente leitura)

Aprovada. Nada foi alterado durante a conferência.

- 4 containers `inforuan-staging-*` em execução, **0 reinícios**.
- Limites efetivos iguais aos da tabela acima.
- Redes: postgres, runner e backup **só** em `inforuan-staging-backend` (interna). O n8n está em `backend` + `egress`. Nenhum container entrou na rede `easypanel`.
- Porta 5679 só em `127.0.0.1`. Pelo túnel, `/healthz` respondeu `{"status":"ok"}`, e a página de login abriu.
- Banco interno do n8n: PostgreSQL 16.15, ~14 MB, 126 tabelas, **1 usuário**, **0 credenciais**.
- Workflows: **4 importados, todos `active = false`** (IR-03, IR-05, IR-06, IR-08).
- Backups lógicos de 14:20 e 14:37 (horário de Brasília) no volume de backups.
- Serviços dos outros projetos com o mesmo tempo de atividade de antes. Nenhum foi reiniciado.
- Memória disponível na VPS: ~3,9 GB. Disco livre: ~80 GB.

## Troca da chave SSH (05/10/2026)

1. Login com a chave `inforuan-staging-claude`, túnel e página do n8n confirmados **antes** da remoção.
2. Cópia de segurança: `/root/.ssh/authorized_keys.bak-2026-10-05-antes-remover-codex`.
3. Removida **somente** a linha da chave temporária da implantação (`inforuan-temporary-2026-10-05`).
4. Resultado: `authorized_keys` com uma única chave (`inforuan-staging-claude`). A chave temporária agora é recusada.

Observação: a chave temporária gerenciada pela Hostinger, que estava na mesma linha por erro de colagem, já tinha sido removida antes, numa etapa anterior. Se o painel da Hostinger precisar dela, ele recria a sua própria chave.

Nenhum conteúdo de chave ou do `.env` foi exibido ou versionado.

## Divergências e pendências registradas

| Item | Situação |
|---|---|
| Snapshot manual da VPS (id 389363) | Expira em **06/10/2026 17:06 UTC**. Renovação não é indispensável (ver doc `14`, seção 15) |
| Pasta `/opt/inforuan-staging/import` | Mantida até a conclusão do commit e da conferência. Remover só depois, com autorização |
| Runner (`inforuan-staging-runner`) | Sem healthcheck próprio; depende do healthcheck do n8n |
| PostgreSQL 16 | Aviso de compatibilidade do n8n. Migração para 17 proposta no doc `14` |
| Versão do n8n (2.35.4) | Mais de 6 semanas. Avaliar atualização depois da migração do banco, em etapa própria |
| Workflows | Ainda usam RPC HTTP com credencial `supabaseApi`. Precisam ser refeitos para o schema `api.*` via `n8n_engine` antes de qualquer ativação |
| Compose antigo do EasyPanel | Obsoleto, arquivado em `infra/_historico/` (só referência) |

## Saída da VPS compartilhada

Depois da validação, migrar o mesmo ambiente para a VPS definitiva, validar a nova instância e então remover desta VPS:

1. containers, redes e volumes com prefixo `inforuan-staging`;
2. diretório `/opt/inforuan-staging`;
3. chave SSH `inforuan-staging-claude` do `authorized_keys`.

Essa remoção não deverá atingir recursos do EasyPanel nem qualquer projeto existente.
