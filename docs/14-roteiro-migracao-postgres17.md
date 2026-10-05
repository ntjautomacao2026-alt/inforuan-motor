# Roteiro — migração do PostgreSQL interno do n8n (16 → 17)

> **Status: PROPOSTO. NÃO EXECUTADO.** Só executar com autorização explícita.
> Escopo: **somente** o banco interno do n8n do staging (`inforuan-staging-postgres`).
> O Supabase do motor **não** é afetado. Nenhum serviço `king`, `n8n` antigo ou `evoltuionapi` é parado, reiniciado ou alterado.

## 1. Por que migrar

O n8n 2.35.4 avisa no início que o PostgreSQL 16 só tem suporte de compatibilidade. A migração deve acontecer **antes** de cadastrar credenciais e de liberar qualquer tráfego, enquanto o banco é pequeno e descartável.

Estado de referência (leitura de 05/10/2026):

| Item | Valor |
|---|---|
| Versão | PostgreSQL 16.15 (Alpine) |
| Tamanho do banco | ~14 MB |
| Tabelas em `public` | 126 |
| Extensões | `plpgsql`, `uuid-ossp` |
| Usuários do n8n | 1 |
| Workflows | 4, todos `active = false` (IR-03, IR-05, IR-06, IR-08) |
| Credenciais | 0 |
| Migrações internas do n8n | 243 |
| Disco livre na VPS | ~80 GB |

## 2. Princípios

1. **Nada é apagado durante a migração.** O volume do PG16 (`inforuan-staging-postgres-data`) fica intacto e **nunca** é montado pelo PG17.
2. O PG17 nasce em um **volume novo**: `inforuan-staging-postgres17-data`.
3. **Mesmo `.env`** e mesma `N8N_ENCRYPTION_KEY`. O volume `inforuan-staging-n8n-data` não muda.
4. Todo comando usa **nome explícito** de container ou `docker compose -p inforuan-staging` dentro de `/opt/inforuan-staging`.
5. **Proibidos** durante e depois da migração, nesta VPS:
   - `docker system prune`, `docker volume prune`, `docker network prune`, `docker image prune`;
   - `docker restart` ou `docker stop` sem nome explícito do INFORUAN;
   - `docker service …`, `docker stack …`, reinício do Docker, `reboot`;
   - qualquer ação no EasyPanel, no Traefik, no firewall ou nas portas globais.
6. **Nenhum segredo é exibido.** O `.env` é copiado, mas nunca é impresso.
7. Nenhum workflow é ativado. Nenhuma credencial é cadastrada. Nada de `pg_cron` nem da migração 0007.

Parada prevista: **somente o staging do INFORUAN**, por cerca de **10 a 15 minutos**.

## 3. Fase A — preparação (sem parada)

```bash
cd /opt/inforuan-staging
install -d -m 700 /opt/inforuan-staging/migracao-pg17
M=/opt/inforuan-staging/migracao-pg17
# Todas as fases rodam na MESMA sessão de shell (as variáveis M, PG16 e PG17 são reaproveitadas).

# A0. Consulta de contagem exata por tabela (usada nas fases C, G e I; testada em leitura em 05/10: 126 linhas).
cat > $M/contagens.sql <<'SQL'
SELECT format('SELECT %L, count(*) FROM %I.%I', table_name, table_schema, table_name)
FROM information_schema.tables
WHERE table_schema = 'public' AND table_type = 'BASE TABLE'
ORDER BY table_name \gexec
SQL

# A1. Linha de base dos OUTROS serviços: nome, imagem e hora de início (para comparar no fim).
docker ps --format '{{.Names}}' | grep -v '^inforuan-staging-' | sort \
  | xargs -r docker inspect --format '{{.Name}} {{.State.StartedAt}} restarts={{.RestartCount}}' > $M/outros-antes.txt
docker service ls --format '{{.Name}} {{.Replicas}} {{.Image}}' | sort > $M/servicos-antes.txt

# A2. Cópias de segurança do compose e do .env (o .env não é exibido).
cp -p docker-compose.yml $M/docker-compose.pg16.yml
cp -p .env $M/env.pg16 && chmod 600 $M/env.pg16
md5sum docker-compose.yml        # deve ser 723878d5275ed369f79ef1dd7184e659

# A3. Baixar as imagens novas ANTES de parar qualquer coisa.
#     Baixar uma tag nova não reinicia nada. A imagem postgres:17 (Debian) que já existe
#     no host pertence a outro projeto e não é usada nem alterada.
docker pull postgres:17-alpine
docker pull prodrigestivill/postgres-backup-local:17
```

**Critério para seguir:** os dois `pull` precisam funcionar e o MD5 precisa conferir. Se algo falhar, **parar aqui**: nada foi alterado.

## 4. Fase B — parada somente do INFORUAN

```bash
docker stop inforuan-staging-runner inforuan-staging-n8n inforuan-staging-pg-backup
docker ps --filter name=inforuan-staging- --format '{{.Names}} {{.Status}}'
# Esperado: só inforuan-staging-postgres em execução.
```

O PostgreSQL 16 continua no ar, sem nenhum cliente, para o dump final.

## 5. Fase C — dump final e validação

```bash
PG16="docker exec inforuan-staging-postgres"

# C1. Contagem exata de linhas por tabela (referência para a comparação).
docker exec -i inforuan-staging-postgres psql -U n8n_inforuan -d n8n_inforuan -At < $M/contagens.sql > $M/contagens-pg16.txt
wc -l $M/contagens-pg16.txt                       # esperado: 126

# C2. Dump final (formato custom), feito DEPOIS da parada do n8n.
$PG16 pg_dump -U n8n_inforuan -d n8n_inforuan -Fc -Z 6 > $M/n8n_inforuan-pg16-final.dump
chmod 600 $M/n8n_inforuan-pg16-final.dump

# C3. Validação do arquivo com o pg_restore do PG17, sem tocar em nenhum banco.
ls -l $M/n8n_inforuan-pg16-final.dump             # tamanho > 0
sha256sum $M/n8n_inforuan-pg16-final.dump | tee $M/n8n_inforuan-pg16-final.dump.sha256
docker run --rm --network none -v $M:/m:ro postgres:17-alpine \
  pg_restore -l /m/n8n_inforuan-pg16-final.dump > $M/dump-lista.txt
grep -c ' TABLE DATA ' $M/dump-lista.txt          # esperado: 126
```

**Critério para seguir:** 126 linhas de contagem, dump legível pelo `pg_restore` do 17, 126 itens `TABLE DATA` e hash registrado. Se falhar: **rollback A** (seção 14).

## 6. Fase D — desligar o projeto antigo (sem apagar volumes)

```bash
docker stop inforuan-staging-postgres
docker compose -p inforuan-staging down        # SEM -v: volumes ficam intactos
docker volume ls --filter name=inforuan-staging- --format '{{.Name}}'
# Esperado: inforuan-staging-n8n-data, inforuan-staging-postgres-data, inforuan-staging-postgres-backups
```

O `down` remove apenas os 4 containers e as 2 redes do projeto `inforuan-staging`. As redes serão recriadas com os mesmos nomes.

## 7. Fase E — compose do PG17

Somente três mudanças em `/opt/inforuan-staging/docker-compose.yml`. O resto fica idêntico, inclusive limites, redes, porta `127.0.0.1:5679` e variáveis.

```diff
   postgres:
-    image: postgres:16-alpine
+    image: postgres:17-alpine
 ...
   pg-backup:
-    image: prodrigestivill/postgres-backup-local:16
+    image: prodrigestivill/postgres-backup-local:17
 ...
 volumes:
   inforuan_pg_data:
-    name: inforuan-staging-postgres-data
+    name: inforuan-staging-postgres17-data
```

```bash
docker compose -p inforuan-staging config --quiet && echo compose-ok
```

A mesma alteração será refletida em `infra/staging/docker-compose.temporary.yml` no repositório, num commit próprio, **depois** da validação.

## 8. Fase F — subir só o PG17 e restaurar

```bash
docker compose -p inforuan-staging up -d postgres
# aguardar healthy
docker inspect -f '{{.State.Health.Status}}' inforuan-staging-postgres   # healthy
PG17="docker exec inforuan-staging-postgres"
$PG17 psql -U n8n_inforuan -d n8n_inforuan -At -c 'select version()'      # PostgreSQL 17.x

# F1. Restauração atômica: tudo ou nada.
docker exec -i inforuan-staging-postgres \
  pg_restore -U n8n_inforuan -d n8n_inforuan --single-transaction --exit-on-error \
  < $M/n8n_inforuan-pg16-final.dump

# F2. Estatísticas do planejador.
$PG17 vacuumdb -U n8n_inforuan -d n8n_inforuan --analyze-only
```

O PG17 é inicializado pelo próprio `.env` (mesmo usuário, mesma senha e mesmo banco). O banco começa vazio, e o dump o preenche.

## 9. Fase G — validação de integridade (antes de ligar o n8n)

```bash
docker exec -i inforuan-staging-postgres psql -U n8n_inforuan -d n8n_inforuan -At < $M/contagens.sql > $M/contagens-pg17.txt
diff $M/contagens-pg16.txt $M/contagens-pg17.txt && echo CONTAGENS-IGUAIS

$PG17 psql -U n8n_inforuan -d n8n_inforuan -At -c 'select count(*) from "user"'               # 1
$PG17 psql -U n8n_inforuan -d n8n_inforuan -At -c 'select name, active from workflow_entity order by name'
# 4 linhas, todas "|f"
$PG17 psql -U n8n_inforuan -d n8n_inforuan -At -c 'select count(*) from credentials_entity'   # 0
$PG17 psql -U n8n_inforuan -d n8n_inforuan -At -c 'select count(*) from migrations'           # 243
$PG17 psql -U n8n_inforuan -d n8n_inforuan -At -c 'select extname from pg_extension order by 1' # plpgsql, uuid-ossp
```

**Critério para seguir:** `diff` vazio e todos os valores esperados. Qualquer diferença leva ao **rollback B**.

## 10. Fase H — ligar o n8n, o runner e o backup

```bash
docker compose -p inforuan-staging up -d
docker ps --filter name=inforuan-staging- --format '{{.Names}} {{.Image}} {{.Status}}'
curl -s http://127.0.0.1:5679/healthz                                  # {"status":"ok"}
docker logs --since 10m inforuan-staging-n8n 2>&1 | grep -iE 'error|encryption|postgres' | head -20
# Esperado: sem erro de migração, sem erro de chave de criptografia e sem o aviso do PG16.

# Os workflows continuam inativos depois da subida:
$PG17 psql -U n8n_inforuan -d n8n_inforuan -At -c 'select name, active from workflow_entity order by name'
```

### Teste de login (feito pelo usuário)

1. No Mac, túnel: `ssh -i ~/.ssh/inforuan_staging -N -L 5679:127.0.0.1:5679 root@<IP da VPS>`.
2. Abrir `http://127.0.0.1:5679` e entrar com a conta proprietária. **A senha é digitada só pelo usuário**, nunca enviada pelo chat.
3. Conferir na tela: os 4 workflows aparecem e todos estão **inativos**. Não ativar nada nem cadastrar credencial.

## 11. Fase I — novo backup e teste de restauração do novo backup

```bash
# I1. Backup imediato com a imagem nova (não espera o @daily).
docker exec inforuan-staging-pg-backup /backup.sh
docker exec inforuan-staging-pg-backup ls -l /backups/last
NOVO=$(docker exec inforuan-staging-pg-backup readlink -f /backups/last/n8n_inforuan-latest.sql.gz)
docker exec inforuan-staging-pg-backup sh -c "zcat $NOVO | head -40" | grep 'Dumped from database version'   # 17.x

# I2. Restauração de teste num banco descartável DENTRO do PG17, depois removido.
$PG17 createdb -U n8n_inforuan restore_test_pg17
docker exec inforuan-staging-pg-backup sh -c "zcat $NOVO" \
  | docker exec -i inforuan-staging-postgres psql -U n8n_inforuan -d restore_test_pg17 -v ON_ERROR_STOP=1 -q
docker exec -i inforuan-staging-postgres psql -U n8n_inforuan -d restore_test_pg17 -At < $M/contagens.sql > $M/contagens-restore-test.txt
diff $M/contagens-pg17.txt $M/contagens-restore-test.txt && echo RESTORE-TEST-OK
$PG17 dropdb -U n8n_inforuan restore_test_pg17
```

Observação: depois do login, a tabela de sessões ou eventos do n8n pode ganhar algumas linhas. Se o `diff` da I2 mostrar diferença **só** nessas tabelas e só por acréscimo, isso é esperado. Qualquer outra diferença bloqueia a conclusão.

## 12. Fase J — conferência final de isolamento

```bash
docker ps --format '{{.Names}}' | grep -v '^inforuan-staging-' | sort \
  | xargs -r docker inspect --format '{{.Name}} {{.State.StartedAt}} restarts={{.RestartCount}}' > $M/outros-depois.txt
docker service ls --format '{{.Name}} {{.Replicas}} {{.Image}}' | sort > $M/servicos-depois.txt
diff $M/outros-antes.txt $M/outros-depois.txt && diff $M/servicos-antes.txt $M/servicos-depois.txt && echo OUTROS-INTACTOS

# Limites, redes e porta do INFORUAN iguais aos de antes.
docker inspect -f '{{.Name}} mem={{.HostConfig.Memory}} cpu={{.HostConfig.NanoCpus}} restarts={{.RestartCount}}' \
  inforuan-staging-postgres inforuan-staging-n8n inforuan-staging-runner inforuan-staging-pg-backup
docker inspect -f '{{.Name}} {{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' \
  inforuan-staging-postgres inforuan-staging-n8n inforuan-staging-runner inforuan-staging-pg-backup
ss -tln | grep 5679        # só 127.0.0.1:5679
```

**Critério de conclusão:** `OUTROS-INTACTOS`, os mesmos limites e redes de antes, a porta só em `127.0.0.1` e 0 reinícios.

## 13. Retenção (48 h)

Ficam guardados por **pelo menos 48 horas** após a conclusão, sem nenhuma alteração:

- volume `inforuan-staging-postgres-data` (PG16, intacto);
- `$M/n8n_inforuan-pg16-final.dump` + `.sha256`;
- `$M/docker-compose.pg16.yml` e `$M/env.pg16` (permissão 600);
- backups antigos do PG16 no volume `inforuan-staging-postgres-backups`.

Regra para essa janela: **não fazer mudanças relevantes no n8n**, como credenciais ou workflows novos. Se houver um rollback, tudo o que foi feito depois da migração se perde.

A remoção do volume do PG16 e dos arquivos de migração **só acontece com nova autorização**, com um comando nomeado (`docker volume rm inforuan-staging-postgres-data`). Nunca com `prune`.

## 14. Rollback

O rollback é possível em qualquer momento da janela de 48 h, porque o volume do PG16 nunca foi montado pelo PG17.

**Rollback A — falha antes da Fase D** (o PG16 ainda está no ar e nada foi derrubado):

```bash
cd /opt/inforuan-staging
docker compose -p inforuan-staging up -d      # religa runner, n8n e backup no PG16 original
```

**Rollback B — falha na Fase D ou depois:**

```bash
cd /opt/inforuan-staging
docker compose -p inforuan-staging down                     # SEM -v
cp -p $M/docker-compose.pg16.yml docker-compose.yml
md5sum docker-compose.yml                                    # 723878d5275ed369f79ef1dd7184e659
docker compose -p inforuan-staging up -d                     # volta para postgres:16-alpine + volume antigo
# Conferir: mesmas contagens de contagens-pg16.txt, 1 usuário, 4 workflows inativos, /healthz ok, login.
```

O `.env` não muda em nenhuma fase. A cópia `env.pg16` é só uma garantia extra. Depois do rollback, o volume `inforuan-staging-postgres17-data` fica parado para análise e só é removido com autorização.

## 15. Snapshot da VPS

**Não é indispensável** para esta migração. A segurança vem de quatro coisas: o volume do PG16 intocado, o dump final validado, os backups lógicos e o rollback por troca de compose.

O snapshot manual atual (id 389363) expira em **06/10/2026 às 17:06 UTC**. Nenhuma renovação é proposta aqui. Se algum dia for considerada, primeiro é preciso confirmar com a Hostinger se a criação do snapshot pausa ou reinicia a VPS e pedir nova autorização, porque ela afeta todos os projetos da máquina.

## 16. Registro após a execução

Ao terminar, atualizar `docs/12-staging-temporario-implantado.md` com:

- data e hora;
- versão final do PostgreSQL;
- hash do dump final;
- resultado do `diff` de contagens;
- resultado do login;
- nome do novo backup e resultado do teste de restauração;
- confirmação `OUTROS-INTACTOS`;
- data a partir da qual o volume do PG16 pode ser removido (com autorização).

Depois, atualizar o compose versionado num commit próprio.
