#!/usr/bin/env bash
set -Eeuo pipefail

[[ ${EUID:-$(id -u)} -eq 0 ]] || { printf '[ERROR] Ejecuta la limpieza con sudo/root.\n' >&2; exit 1; }
[[ "${1:-}" == "--yes" ]] || { printf '[ERROR] Esta operación borra todo el WEB antiguo. Usa: %s --yes\n' "$0" >&2; exit 1; }

ROOT_PREFIX="${TM_PURGE_ROOT:-}"
[[ "$ROOT_PREFIX" != "/" ]] || { printf '[ERROR] TM_PURGE_ROOT no puede ser /.\n' >&2; exit 1; }
path(){ printf '%s%s' "$ROOT_PREFIX" "$1"; }
live=0; [[ -z "$ROOT_PREFIX" ]] && live=1

services=(
  timesmedia-web.service
  timesmedia-scheduler.service
  mediavps.service
  mediavps-web.service
  mediavps-scheduler.service
)

printf '[TimesMedia] Deteniendo servicios y procesos WEB antiguos...\n'
if (( live )); then
  systemctl disable --now "${services[@]}" 2>/dev/null || true
  process_pattern='(/opt/timesmedia-web|/home/ubuntu/web/mediavps|/root/mediavps-web|/mediavps-web)'
  pkill -TERM -f -- "$process_pattern" 2>/dev/null || true
  sleep 1
  pkill -KILL -f -- "$process_pattern" 2>/dev/null || true
fi

printf '[TimesMedia] Eliminando unidades systemd exclusivas del WEB...\n'
for unit_root in /etc/systemd/system /lib/systemd/system /usr/lib/systemd/system; do
  for service in "${services[@]}"; do
    rm -f -- "$(path "$unit_root/$service")"
  done
done
rm -rf -- \
  "$(path /etc/systemd/system/timesmedia-web.service.d)" \
  "$(path /etc/systemd/system/timesmedia-scheduler.service.d)" \
  "$(path /etc/systemd/system/mediavps.service.d)" \
  "$(path /etc/systemd/system/mediavps-web.service.d)" \
  "$(path /etc/systemd/system/mediavps-scheduler.service.d)"

systemd_root=$(path /etc/systemd/system)
if [[ -d "$systemd_root" ]]; then
  find "$systemd_root" -type l \( \
    -name timesmedia-web.service -o \
    -name timesmedia-scheduler.service -o \
    -name mediavps.service -o \
    -name mediavps-web.service -o \
    -name mediavps-scheduler.service \
  \) -delete
fi

printf '[TimesMedia] Eliminando código, configuración y estado WEB antiguos...\n'
rm -rf -- \
  "$(path /opt/timesmedia-web)" \
  "$(path /opt/timesmedia-web.previous)" \
  "$(path /var/lib/timesmedia-web)" \
  "$(path /home/ubuntu/web/mediavps)" \
  "$(path /root/mediavps-web)" \
  "$(path /mediavps-web)" \
  "$(path /etc/timesmedia/web.env)"

for parent_pattern in \
  "$(path /opt)/.timesmedia-web.stage.*" \
  "$(path /var/lib)/timesmedia-web.pre-migration.*"; do
  parent=${parent_pattern%/*}
  pattern=${parent_pattern##*/}
  [[ ! -d "$parent" ]] || find "$parent" -mindepth 1 -maxdepth 1 -name "$pattern" -exec rm -rf -- {} +
done

rm -f -- \
  "$(path /etc/cron.d/timesmedia-web)" \
  "$(path /etc/cron.d/mediavps)" \
  "$(path /etc/cron.d/mediavps-web)"
rmdir "$(path /etc/timesmedia)" 2>/dev/null || true

# The CLI is shared with NODE; preserve it whenever NODE exists.
if [[ ! -e "$(path /etc/timesmedia/node.env)" && ! -d "$(path /opt/timesmedia-node)" && ! -d "$(path /var/lib/timesmedia-node)" ]]; then
  rm -rf -- "$(path /usr/local/lib/timesmedia)"
  rm -f -- "$(path /usr/local/sbin/timesmedia)"
fi

if (( live )); then
  systemctl daemon-reload
  systemctl reset-failed "${services[@]}" 2>/dev/null || true
  userdel timesmedia-web 2>/dev/null || true
  groupdel timesmedia-web 2>/dev/null || true
  find /run -maxdepth 1 -type f \( -name 'timesmedia-gh-token.*' -o -name 'timesmedia-askpass.*' \) -mmin +10 -delete 2>/dev/null || true
  find /tmp -maxdepth 1 -type d -name 'timesmedia-bootstrap.*' -mmin +10 -exec rm -rf -- {} + 2>/dev/null || true
fi

failed=0
targets=(
  /opt/timesmedia-web
  /var/lib/timesmedia-web
  /home/ubuntu/web/mediavps
  /root/mediavps-web
  /mediavps-web
  /etc/timesmedia/web.env
)
for target in "${targets[@]}"; do
  if [[ -e "$(path "$target")" ]]; then
    printf '[ERROR] Persistió: %s\n' "$target" >&2
    failed=1
  fi
done

if (( live )); then
  if pgrep -f -- '(/opt/timesmedia-web|/home/ubuntu/web/mediavps|/root/mediavps-web|/mediavps-web)' >/dev/null 2>&1; then
    printf '[ERROR] Aún existe un proceso WEB antiguo.\n' >&2
    failed=1
  fi
  if command -v ss >/dev/null 2>&1 && ss -lntup 2>/dev/null | grep -Eq ':5000\b'; then
    printf '[ERROR] Aún existe un listener en 5000; revisa qué proyecto lo utiliza antes de instalar.\n' >&2
    failed=1
  fi
fi

(( failed == 0 )) || exit 1
printf '[OK] MediaVPS WEB y TimesMedia WEB fueron eliminados completamente.\n'
printf '[OK] cloudflared, SSH, NODE y los demás proyectos no fueron modificados.\n'
