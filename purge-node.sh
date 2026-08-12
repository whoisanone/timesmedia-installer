#!/usr/bin/env bash
set -Eeuo pipefail

[[ ${EUID:-$(id -u)} -eq 0 ]] || { printf '[ERROR] Ejecuta la limpieza con sudo/root.\n' >&2; exit 1; }
[[ "${1:-}" == "--yes" ]] || { printf '[ERROR] Esta operación borra todo el NODE. Usa: %s --yes\n' "$0" >&2; exit 1; }

ROOT_PREFIX="${TM_PURGE_ROOT:-}"
[[ "$ROOT_PREFIX" != "/" ]] || { printf '[ERROR] TM_PURGE_ROOT no puede ser /.\n' >&2; exit 1; }

path(){ printf '%s%s' "$ROOT_PREFIX" "$1"; }
live=0; [[ -z "$ROOT_PREFIX" ]] && live=1

services=(
  timesmedia-node.service
  timesmedia-worker.service
  mediavps-node.service
  mediavps-worker.service
)

node_env=$(path /etc/timesmedia/node.env)
bt_port=6883
if [[ -f "$node_env" ]]; then
  configured_port=$(sed -n 's/^NODE_TORRENT_PORT=//p' "$node_env" | tail -n1)
  [[ "$configured_port" =~ ^[0-9]+$ ]] && (( configured_port >= 1 && configured_port <= 65535 )) && bt_port="$configured_port"
fi

printf '[TimesMedia] Deteniendo servicios y procesos NODE...\n'
if (( live )); then
  systemctl disable --now "${services[@]}" 2>/dev/null || true
  process_pattern='(/opt/timesmedia-node|/root/mediavps-node|/mediavps-node|/home/ubuntu/mediavps-node)'
  pkill -TERM -f -- "$process_pattern" 2>/dev/null || true
  sleep 1
  pkill -KILL -f -- "$process_pattern" 2>/dev/null || true
fi

printf '[TimesMedia] Eliminando unidades systemd del NODE...\n'
for unit_root in /etc/systemd/system /lib/systemd/system /usr/lib/systemd/system; do
  for service in "${services[@]}"; do
    rm -f -- "$(path "$unit_root/$service")"
  done
done
rm -rf -- \
  "$(path /etc/systemd/system/timesmedia-node.service.d)" \
  "$(path /etc/systemd/system/timesmedia-worker.service.d)" \
  "$(path /etc/systemd/system/mediavps-node.service.d)" \
  "$(path /etc/systemd/system/mediavps-worker.service.d)"

systemd_root=$(path /etc/systemd/system)
if [[ -d "$systemd_root" ]]; then
  find "$systemd_root" -type l \( \
    -name timesmedia-node.service -o \
    -name timesmedia-worker.service -o \
    -name mediavps-node.service -o \
    -name mediavps-worker.service \
  \) -delete
fi

printf '[TimesMedia] Eliminando código, configuración, estado y multimedia NODE...\n'
rm -rf -- \
  "$(path /opt/timesmedia-node)" \
  "$(path /opt/timesmedia-node.previous)" \
  "$(path /var/lib/timesmedia-node)" \
  "$(path /srv/timesmedia)" \
  "$(path /root/mediavps-node)" \
  "$(path /mediavps-node)" \
  "$(path /root/mediavps-storage)" \
  "$(path /home/ubuntu/mediavps-node)" \
  "$(path /home/ubuntu/mediavps-storage)" \
  "$node_env"

for parent_pattern in \
  "$(path /opt)/.timesmedia-node.stage.*" \
  "$(path /var/lib)/timesmedia-node.pre-migration.*"; do
  parent=${parent_pattern%/*}
  pattern=${parent_pattern##*/}
  [[ ! -d "$parent" ]] || find "$parent" -mindepth 1 -maxdepth 1 -name "$pattern" -exec rm -rf -- {} +
done

rm -f -- \
  "$(path /etc/cron.d/timesmedia-node)" \
  "$(path /etc/cron.d/mediavps-node)"

rmdir "$(path /etc/timesmedia)" 2>/dev/null || true

# The CLI is shared with WEB; remove it only when no WEB installation exists.
if [[ ! -e "$(path /etc/timesmedia/web.env)" && ! -d "$(path /opt/timesmedia-web)" && ! -d "$(path /var/lib/timesmedia-web)" ]]; then
  rm -rf -- "$(path /usr/local/lib/timesmedia)"
  rm -f -- "$(path /usr/local/sbin/timesmedia)"
fi

if (( live )); then
  if command -v ufw >/dev/null 2>&1; then
    mapfile -t firewall_rules < <(
      ufw status numbered 2>/dev/null \
        | sed -nE "/(^|[^0-9])(5100|${bt_port})([^0-9]|$)/ s/^\[[[:space:]]*([0-9]+)\].*/\1/p" \
        | sort -rn
    )
    for rule in "${firewall_rules[@]}"; do
      ufw --force delete "$rule" >/dev/null 2>&1 || true
    done
  fi

  systemctl daemon-reload
  systemctl reset-failed "${services[@]}" 2>/dev/null || true
  userdel timesmedia-node 2>/dev/null || true
  groupdel timesmedia-node 2>/dev/null || true
  find /run -maxdepth 1 -type f \( -name 'timesmedia-gh-token.*' -o -name 'timesmedia-askpass.*' \) -mmin +10 -delete 2>/dev/null || true
  find /tmp -maxdepth 1 -type d -name 'timesmedia-auth.*' -mmin +10 -exec rm -rf -- {} + 2>/dev/null || true
  find /tmp -maxdepth 1 -type d -name 'timesmedia-bootstrap.*' -mmin +10 -exec rm -rf -- {} + 2>/dev/null || true
fi

failed=0
targets=(
  /opt/timesmedia-node
  /var/lib/timesmedia-node
  /srv/timesmedia
  /root/mediavps-node
  /mediavps-node
  /root/mediavps-storage
  /home/ubuntu/mediavps-node
  /home/ubuntu/mediavps-storage
  /etc/timesmedia/node.env
)
for target in "${targets[@]}"; do
  if [[ -e "$(path "$target")" ]]; then
    printf '[ERROR] Persistió: %s\n' "$target" >&2
    failed=1
  fi
done

if (( live )); then
  if pgrep -f -- '(/opt/timesmedia-node|/root/mediavps-node|/mediavps-node|/home/ubuntu/mediavps-node)' >/dev/null 2>&1; then
    printf '[ERROR] Aún existe un proceso NODE antiguo.\n' >&2
    failed=1
  fi
  if command -v ss >/dev/null 2>&1 && ss -lntup 2>/dev/null | grep -Eq ":(5100|${bt_port})\\b"; then
    printf '[ERROR] Aún existe un listener en 5100 o %s.\n' "$bt_port" >&2
    failed=1
  fi
fi

(( failed == 0 )) || exit 1
printf '[OK] MediaVPS NODE y TimesMedia NODE fueron eliminados completamente.\n'
printf '[OK] TimesMedia WEB y los demás proyectos no fueron modificados.\n'
