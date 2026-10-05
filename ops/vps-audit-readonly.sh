#!/usr/bin/env bash
# INFORUAN — Auditoria SOMENTE LEITURA da VPS compartilhada (KVM 2 / EasyPanel).
# NÃO altera, NÃO reinicia, NÃO instala, NÃO cria nada. Só lê e imprime.
# Não imprime segredos: variáveis de ambiente dos containers NÃO são listadas
# (exceto WEBHOOK_GLOBAL_*, com a URL cortada no domínio).
# Uso (a partir do Mac): ssh <usuario>@<ip> 'bash -s' < ops/vps-audit-readonly.sh
set -u
sec(){ printf '\n===== %s =====\n' "$1"; }
have(){ command -v "$1" >/dev/null 2>&1; }

sec "SISTEMA"
uname -sr; grep -E '^(PRETTY_NAME)=' /etc/os-release; uptime; echo "vCPUs: $(nproc)"

sec "MEMÓRIA (MB)"
free -m

sec "DISCO"
df -hT -x tmpfs -x devtmpfs -x overlay -x squashfs 2>/dev/null

sec "CARGA AGORA (top 15)"
top -bn1 | head -20

sec "HISTÓRICO CPU/MEMÓRIA (sar, se instalado)"
if have sar; then sar -u 2>/dev/null | tail -15; sar -r 2>/dev/null | tail -15; else echo "sar não instalado — picos virão do painel da Hostinger"; fi

sec "DOCKER — VERSÃO E MODO"
docker version --format 'docker {{.Server.Version}}' 2>/dev/null
docker info --format 'swarm={{.Swarm.LocalNodeState}} containers={{.Containers}} running={{.ContainersRunning}} images={{.Images}}' 2>/dev/null

sec "DOCKER — USO DE DISCO"
docker system df 2>/dev/null

sec "CONTAINERS"
docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null

sec "CONSUMO POR CONTAINER (instantâneo)"
docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.NetIO}}\t{{.BlockIO}}' 2>/dev/null

sec "SERVIÇOS SWARM (EasyPanel) E LIMITES"
if docker service ls >/dev/null 2>&1; then
  docker service ls --format 'table {{.Name}}\t{{.Mode}}\t{{.Replicas}}\t{{.Image}}'
  echo
  for s in $(docker service ls -q); do
    docker service inspect "$s" --format '{{.Spec.Name}}  cpu_limit={{with .Spec.TaskTemplate.Resources}}{{with .Limits}}{{.NanoCPUs}}{{end}}{{end}}  mem_limit={{with .Spec.TaskTemplate.Resources}}{{with .Limits}}{{.MemoryBytes}}{{end}}{{end}}'
  done
else
  echo "sem swarm"
fi

sec "PROJETOS DO EASYPANEL (prefixo dos serviços)"
docker service ls --format '{{.Name}}' 2>/dev/null | awk -F_ '{print $1}' | sort | uniq -c

sec "REDES DOCKER"
docker network ls --format 'table {{.Name}}\t{{.Driver}}\t{{.Scope}}' 2>/dev/null

sec "VOLUMES DOCKER"
docker volume ls --format '{{.Name}}' 2>/dev/null
echo; echo "Tamanho dos volumes:"; docker system df -v 2>/dev/null | sed -n '/VOLUME NAME/,/^$/p' | head -60

sec "PORTAS ESCUTANDO NO HOST"
ss -tlnp 2>/dev/null | awk 'NR==1 || /LISTEN/ {print $1, $4, $6}'

sec "FIREWALL"
(have ufw && ufw status verbose) 2>/dev/null || echo "ufw ausente"
iptables -S INPUT 2>/dev/null | head -25

sec "PROXY"
docker ps --format '{{.Names}}  {{.Image}}' 2>/dev/null | grep -iE 'traefik|caddy|nginx|easypanel' || echo "nenhum proxy em container"

sec "DOMÍNIOS ROTEADOS (só os hosts)"
grep -rhoE 'Host\(`[^`]+`\)' /etc/easypanel/traefik 2>/dev/null | sort -u || echo "config do Traefik do EasyPanel não encontrada em /etc/easypanel/traefik"

sec "WEBHOOKS GLOBAIS (Evolution e similares) — URL cortada no domínio"
for c in $(docker ps -q 2>/dev/null); do
  n=$(docker inspect "$c" --format '{{.Name}}')
  docker inspect "$c" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
    | grep -E '^WEBHOOK_GLOBAL_(ENABLED|URL|WEBHOOK_BY_EVENTS)=' \
    | sed -E 's#(https?://[^/]+).*#\1/…#' | sed "s#^#$n  #"
done
echo "(fim — se nada apareceu acima, nenhum container define webhook global)"

sec "BACKUPS / AGENDAMENTOS NO HOST"
crontab -l 2>/dev/null || echo "sem crontab do usuário atual"
ls -1 /etc/cron.d 2>/dev/null
systemctl list-timers --all --no-pager 2>/dev/null | head -20

sec "EASYPANEL"
docker service inspect easypanel --format 'imagem: {{.Spec.TaskTemplate.ContainerSpec.Image}}' 2>/dev/null || echo "serviço easypanel não encontrado com esse nome"

sec "FIM — nada foi alterado"
