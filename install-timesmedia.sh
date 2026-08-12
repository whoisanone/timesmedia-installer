#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
need_root
INSTALLER_VERSION=$(<"$SCRIPT_DIR/VERSION")

WEB_CODE=/opt/timesmedia-web
WEB_STATE=/var/lib/timesmedia-web
WEB_ENV=/etc/timesmedia/web.env
NODE_CODE=/opt/timesmedia-node
NODE_STATE=/var/lib/timesmedia-node
NODE_MEDIA=/srv/timesmedia/media
NODE_ENV=/etc/timesmedia/node.env
TM_NODE_CUTOVER_ACTIVE=0
TM_NODE_STATE_BACKUP=""
TM_MEDIA_MOVED=0
TM_FRESH_NODE=0
TM_FRESH_WEB=0

installer_cleanup(){
  local rc="$1"
  trap - EXIT
  if [[ "$TM_NODE_CUTOVER_ACTIVE" == 1 ]]; then
    systemctl stop timesmedia-node.service timesmedia-worker.service 2>/dev/null || true
    rollback_code "$NODE_CODE" || true
    rollback_node_legacy || true
  fi
  _tm_cleanup
  exit "$rc"
}
trap 'installer_cleanup "$?"' EXIT

read_secret_twice(){
  local label="$1" a b
  while :; do
    read -r -s -p "$label: " a; printf '\n'
    read -r -s -p "Repite $label: " b; printf '\n'
    [[ "$a" == "$b" ]] || { warn "No coinciden."; continue; }
    [[ ${#a} -ge 12 ]] || { warn "Usa al menos 12 caracteres."; continue; }
    REPLY="$a"; unset b; return 0
  done
}

legacy_web_migrate(){
  local old=/home/ubuntu/web/mediavps
  [[ -d "$old" ]] || return 0
  [[ ! -e "$WEB_STATE/timesmedia.sqlite3" ]] || return 0
  confirm "Encontré MediaVPS WEB. ¿Copiar DB/portadas/configuración a TimesMedia?" || return 0
  log "Migrando estado WEB sin modificar la instalación antigua..."
  install -d -m 700 -o timesmedia-web -g timesmedia-web "$WEB_STATE" "$WEB_STATE/covers" "$WEB_STATE/features" "$WEB_STATE/cache" "$WEB_STATE/vendor"
  if [[ -f "$old/data/mediavps.sqlite3" ]]; then
    OLD_DB="$old/data/mediavps.sqlite3" NEW_DB="$WEB_STATE/timesmedia.sqlite3" runuser -u timesmedia-web -- env OLD_DB="$old/data/mediavps.sqlite3" NEW_DB="$WEB_STATE/timesmedia.sqlite3" python3 - <<'PY'
import os, sqlite3
src=sqlite3.connect(f"file:{os.environ['OLD_DB']}?mode=ro", uri=True)
dst=sqlite3.connect(os.environ['NEW_DB'])
with dst: src.backup(dst)
dst.close(); src.close()
PY
  fi
  [[ -d "$old/covers" ]] && cp -a "$old/covers/." "$WEB_STATE/covers/" || true
  [[ -d "$old/features" ]] && cp -a "$old/features/." "$WEB_STATE/features/" || true
  [[ -f "$old/data/cookies.txt" ]] && cp -a "$old/data/cookies.txt" "$WEB_STATE/cookies.txt" || true
  local secret=""
  if [[ -f "$old/.env" ]]; then
    secret=$(sed -n 's/^SECRET_KEY=//p' "$old/.env" | tail -n1 | tr -d '\r' || true)
    secret=${secret%\"}; secret=${secret#\"}; secret=${secret%\'}; secret=${secret#\'}
  fi
  if [[ ${#secret} -ge 32 ]]; then
    printf '%s' "$secret" > "$WEB_STATE/.secret_key"
  elif [[ -f "$old/data/.secret_key" ]]; then
    cp -a "$old/data/.secret_key" "$WEB_STATE/.secret_key"
  fi
  unset secret
  chown -R timesmedia-web:timesmedia-web "$WEB_STATE"
  find "$WEB_STATE" -type d -exec chmod 700 {} +
  [[ -f "$WEB_STATE/.secret_key" ]] && chmod 600 "$WEB_STATE/.secret_key"
  ok "Estado WEB copiado. MediaVPS antiguo sigue intacto."
}

fresh_web_reset(){
  log "Modo limpio: eliminando exclusivamente instalaciones WEB anteriores..."
  systemctl disable --now \
    timesmedia-web.service timesmedia-scheduler.service \
    mediavps.service mediavps-web.service mediavps-scheduler.service 2>/dev/null || true
  local process_pattern service unit_root
  process_pattern='(/opt/timesmedia-web|/home/ubuntu/web/mediavps|/root/mediavps-web|/mediavps-web)'
  pkill -TERM -f -- "$process_pattern" 2>/dev/null || true
  sleep 1
  pkill -KILL -f -- "$process_pattern" 2>/dev/null || true
  for unit_root in /etc/systemd/system /lib/systemd/system /usr/lib/systemd/system; do
    for service in \
      timesmedia-web.service timesmedia-scheduler.service \
      mediavps.service mediavps-web.service mediavps-scheduler.service; do
      rm -f -- "$unit_root/$service"
    done
  done
  rm -rf -- \
    /etc/systemd/system/timesmedia-web.service.d \
    /etc/systemd/system/timesmedia-scheduler.service.d \
    "$WEB_CODE" "${WEB_CODE}.previous" \
    "$WEB_STATE" "$WEB_ENV" \
    /home/ubuntu/web/mediavps /root/mediavps-web /mediavps-web
  systemctl daemon-reload
  userdel timesmedia-web 2>/dev/null || true
  groupdel timesmedia-web 2>/dev/null || true
  if command -v ss >/dev/null 2>&1 && ss -lntup 2>/dev/null | grep -Eq ':5000\b'; then
    die "El puerto 5000 sigue ocupado por otro proceso; no instalaré encima de otro proyecto."
  fi
  ok "WEB anterior eliminado; cloudflared, SSH, NODE y otros proyectos no fueron modificados."
}

install_web(){
  local mode="${1:-}"
  [[ -z "$mode" || "$mode" == "--fresh" ]] || die "Uso: $0 web [--fresh]"
  [[ "$mode" != "--fresh" ]] || TM_FRESH_WEB=1
  log "Preparando TimesMedia WEB ${INSTALLER_VERSION}..."
  apt_install ca-certificates curl git python3 python3-venv
  install -d -m 755 /opt /etc/timesmedia

  # Obtain and validate a complete private checkout before deleting anything.
  atomic_code_install "$TM_WEB_REPO" "$WEB_CODE"
  local stage="$TM_STAGE"
  local required
  for required in \
    requirements.txt .env.example app.py manage.py scheduler.py scripts/vendor_hls.py \
    deploy/systemd/timesmedia-web.service deploy/systemd/timesmedia-scheduler.service \
    static/admin.js static/media.js; do
    [[ -f "$stage/$required" ]] || die "El repositorio WEB está incompleto: falta $required"
  done

  if [[ "$TM_FRESH_WEB" == 1 ]]; then
    fresh_web_reset
  fi

  ensure_user timesmedia-web "$WEB_STATE"
  install -d -m 755 /opt /etc/timesmedia
  secure_mkdir timesmedia-web 700 "$WEB_STATE"
  for d in covers features cache vendor; do secure_mkdir timesmedia-web 700 "$WEB_STATE/$d"; done
  chown -R timesmedia-web:timesmedia-web "$stage"

  if [[ ! -f "$WEB_ENV" ]]; then
    install -m 600 -o root -g root "$stage/.env.example" "$WEB_ENV"
    local domain
    domain="${TM_WEB_DOMAIN:-}"
    if [[ -z "$domain" ]]; then
      read -r -p "Dominio público (ej. app.example.com; vacío = solo localhost): " domain
    fi
    if [[ -n "$domain" ]]; then
      [[ "$domain" =~ ^[A-Za-z0-9.-]+$ ]] || die "Dominio inválido."
      write_kv "$WEB_ENV" TRUSTED_HOSTS "$domain,localhost,127.0.0.1"
      write_kv "$WEB_ENV" TRUST_PROXY 1
    else
      write_kv "$WEB_ENV" TRUSTED_HOSTS "localhost,127.0.0.1"
      write_kv "$WEB_ENV" TRUST_PROXY 0
      write_kv "$WEB_ENV" SESSION_COOKIE_SECURE 0
    fi
    local cores workers
    cores=$(nproc 2>/dev/null || echo 1); workers=$(( cores > 2 ? 3 : cores > 1 ? 2 : 1 ))
    write_kv "$WEB_ENV" WEB_WORKERS "$workers"
    chmod 600 "$WEB_ENV"
  fi

  if [[ "$TM_FRESH_WEB" != 1 ]]; then
    legacy_web_migrate
  fi

  systemctl stop timesmedia-web.service timesmedia-scheduler.service 2>/dev/null || true
  swap_code "$stage" "$WEB_CODE"
  chown -R timesmedia-web:timesmedia-web "$WEB_CODE"
  if ! python_venv_build_as timesmedia-web "$WEB_CODE"; then
    rollback_code "$WEB_CODE"
    die "No se pudo construir el entorno Python del WEB en su ruta final."
  fi
  if ! python_module_check_as timesmedia-web "$WEB_CODE" gunicorn --version >/dev/null; then
    rollback_code "$WEB_CODE"
    die "Gunicorn no es ejecutable desde el entorno final del WEB."
  fi
  local -a web_environment=()
  mapfile -t web_environment < <(sed -nE '/^[A-Za-z_][A-Za-z0-9_]*=/p' "$WEB_ENV")
  if ! (cd "$WEB_CODE" && runuser -u timesmedia-web -- env "${web_environment[@]}" "$WEB_CODE/.venv/bin/python" -c 'from app import app; assert app'); then
    rollback_code "$WEB_CODE"
    die "La aplicación WEB no se puede importar desde su instalación final."
  fi
  if ! (cd "$WEB_CODE" && runuser -u timesmedia-web -- env TIMESMEDIA_VENDOR_DIR="$WEB_STATE/vendor" "$WEB_CODE/.venv/bin/python" scripts/vendor_hls.py --dest "$WEB_STATE/vendor/hls.min.js"); then
    warn "No pude descargar hls.js ahora. Se conservará el reproductor HTML5 directo."
  fi
  install -m 644 "$WEB_CODE/deploy/systemd/timesmedia-web.service" /etc/systemd/system/timesmedia-web.service
  install -m 644 "$WEB_CODE/deploy/systemd/timesmedia-scheduler.service" /etc/systemd/system/timesmedia-scheduler.service
  systemctl daemon-reload

  local admin password
  local user_count
  user_count=$(cd "$WEB_CODE" && runuser -u timesmedia-web -- env PYTHONPATH="$WEB_CODE" TIMESMEDIA_STATE_DIR="$WEB_STATE" TIMESMEDIA_DB_PATH="$WEB_STATE/timesmedia.sqlite3" TIMESMEDIA_COVERS_DIR="$WEB_STATE/covers" TIMESMEDIA_FEATURES_DIR="$WEB_STATE/features" TIMESMEDIA_CACHE_DIR="$WEB_STATE/cache" TIMESMEDIA_VENDOR_DIR="$WEB_STATE/vendor" TIMESMEDIA_SECRET_PATH="$WEB_STATE/.secret_key" "$WEB_CODE/.venv/bin/python" -c 'from core import db; db.init_db(); print(db.scalar("SELECT COUNT(*) AS n FROM users",(),0) or 0)')
  if [[ "$user_count" == "0" ]]; then
    read -r -p "Usuario administrador inicial [admin]: " admin; admin=${admin:-admin}
    read_secret_twice "Contraseña admin"; password=$REPLY
    cd "$WEB_CODE"
    printf '%s\n' "$password" | runuser -u timesmedia-web -- env PYTHONPATH="$WEB_CODE" TIMESMEDIA_STATE_DIR="$WEB_STATE" TIMESMEDIA_DB_PATH="$WEB_STATE/timesmedia.sqlite3" TIMESMEDIA_COVERS_DIR="$WEB_STATE/covers" TIMESMEDIA_FEATURES_DIR="$WEB_STATE/features" TIMESMEDIA_CACHE_DIR="$WEB_STATE/cache" TIMESMEDIA_VENDOR_DIR="$WEB_STATE/vendor" TIMESMEDIA_SECRET_PATH="$WEB_STATE/.secret_key" "$WEB_CODE/.venv/bin/python" manage.py create-admin "$admin"
    unset password REPLY
  fi

  if [[ "$TM_FRESH_WEB" != 1 ]] && service_exists mediavps.service && service_active mediavps.service; then
    warn "mediavps.service sigue usando el puerto 5000. Para el corte final debe detenerse."
    if confirm "¿Detener MediaVPS WEB y activar TimesMedia ahora?"; then
      systemctl stop mediavps.service
      systemctl disable mediavps.service >/dev/null 2>&1 || true
    else
      warn "TimesMedia WEB quedó instalado pero no se iniciará para evitar conflicto de puerto."
      install_cli
      return 0
    fi
  fi

  if ! systemctl enable --now timesmedia-web.service timesmedia-scheduler.service; then
    rollback_code "$WEB_CODE"; systemctl daemon-reload
    [[ "$TM_FRESH_WEB" == 1 ]] || { service_exists mediavps.service && systemctl start mediavps.service 2>/dev/null || true; }
    die "TimesMedia WEB no inició; código revertido y MediaVPS intentó restaurarse."
  fi
  if ! wait_http http://127.0.0.1:5000/health 30 || ! wait_http http://127.0.0.1:5000/ 5; then
    journalctl -u timesmedia-web.service -n 40 --no-pager >&2 || true
    systemctl stop timesmedia-web.service timesmedia-scheduler.service || true
    rollback_code "$WEB_CODE"
    [[ "$TM_FRESH_WEB" == 1 ]] || { service_exists mediavps.service && systemctl start mediavps.service 2>/dev/null || true; }
    die "Health check WEB falló en la API o portada; se ejecutó rollback."
  fi
  install_cli
  ok "TimesMedia WEB instalado y saludable."
}

legacy_node_migrate(){
  [[ ! -e "$NODE_STATE/node.sqlite3" ]] || return 0
  local old_code="" old_media=""
  [[ -d /root/mediavps-node ]] && old_code=/root/mediavps-node
  [[ -z "$old_code" && -d /mediavps-node ]] && old_code=/mediavps-node
  [[ -d /root/mediavps-storage ]] && old_media=/root/mediavps-storage
  [[ -n "$old_code" || -n "$old_media" ]] || return 0
  confirm "Encontré MediaVPS NODE. ¿Preparar migración de estado/media al layout TimesMedia?" || return 0
  TM_LEGACY_NODE_CODE="$old_code"; TM_LEGACY_MEDIA="$old_media"; TM_LEGACY_MIGRATE=1
}

preflight_node_cutover_migration(){
  [[ "${TM_LEGACY_MIGRATE:-0}" == 1 ]] || return 0
  local old_media="${TM_LEGACY_MEDIA:-}" srcdev dstdev
  [[ -n "$old_media" && -d "$old_media" && "$old_media" != "$NODE_MEDIA" ]] || return 0
  if [[ -d "$NODE_MEDIA" ]] && find "$NODE_MEDIA" -mindepth 1 -print -quit | grep -q .; then
    die "El destino $NODE_MEDIA no está vacío; no moveré el storage legado."
  fi
  srcdev=$(stat -c %d "$old_media")
  dstdev=$(stat -c %d "$(dirname "$NODE_MEDIA")")
  [[ "$srcdev" == "$dstdev" ]] || die "El storage legado está en otro filesystem. Migra los datos manualmente antes del corte."
}

perform_node_cutover_migration(){
  [[ "${TM_LEGACY_MIGRATE:-0}" == 1 ]] || return 0
  local old_code="${TM_LEGACY_NODE_CODE:-}" old_media="${TM_LEGACY_MEDIA:-}"
  TM_NODE_CUTOVER_ACTIVE=1
  systemctl stop mediavps-worker.service mediavps-node.service 2>/dev/null || true
  if [[ -n "$old_code" && -d "$old_code/data" && ! -e "$NODE_STATE/node.sqlite3" ]]; then
    local state_backup="${NODE_STATE}.pre-migration.$$"
    rm -rf -- "$state_backup" || return 1
    mv "$NODE_STATE" "$state_backup" || return 1
    TM_NODE_STATE_BACKUP="$state_backup"
    secure_mkdir timesmedia-node 700 "$NODE_STATE" || return 1
    local d
    for d in cache posters fallback hls torrents aria2; do
      secure_mkdir timesmedia-node 700 "$NODE_STATE/$d" || return 1
    done
    cp -a "$old_code/data/." "$NODE_STATE/" || return 1
  fi
  chown -R timesmedia-node:timesmedia-node "$NODE_STATE" || return 1
  if [[ -n "$old_media" && -d "$old_media" && "$old_media" != "$NODE_MEDIA" ]]; then
    rmdir "$NODE_MEDIA" 2>/dev/null || true
    mv "$old_media" "$NODE_MEDIA" || return 1
    TM_MEDIA_MOVED=1
    chown -R timesmedia-node:timesmedia-node "$NODE_MEDIA" || return 1
  fi
}

rollback_node_legacy(){
  if [[ "${TM_MEDIA_MOVED:-0}" == 1 && -n "${TM_LEGACY_MEDIA:-}" && -d "$NODE_MEDIA" ]]; then
    mv "$NODE_MEDIA" "$TM_LEGACY_MEDIA" || true
  fi
  if [[ -n "${TM_NODE_STATE_BACKUP:-}" && -d "$TM_NODE_STATE_BACKUP" ]]; then
    rm -rf -- "$NODE_STATE" || true
    mv "$TM_NODE_STATE_BACKUP" "$NODE_STATE" || true
  fi
  TM_MEDIA_MOVED=0; TM_NODE_STATE_BACKUP=""; TM_NODE_CUTOVER_ACTIVE=0
  if [[ "$TM_FRESH_NODE" != 1 ]]; then
    systemctl start mediavps-node.service mediavps-worker.service 2>/dev/null || true
  fi
}

commit_node_legacy(){
  if [[ -n "${TM_NODE_STATE_BACKUP:-}" && -d "$TM_NODE_STATE_BACKUP" ]]; then
    rm -rf -- "$TM_NODE_STATE_BACKUP"
  fi
  TM_MEDIA_MOVED=0; TM_NODE_STATE_BACKUP=""; TM_NODE_CUTOVER_ACTIVE=0
}

fresh_node_reset(){
  log "Modo limpio: eliminando exclusivamente instalaciones NODE anteriores..."
  systemctl disable --now \
    timesmedia-node.service timesmedia-worker.service \
    mediavps-node.service mediavps-worker.service 2>/dev/null || true
  rm -f -- \
    /etc/systemd/system/timesmedia-node.service \
    /etc/systemd/system/timesmedia-worker.service \
    /etc/systemd/system/mediavps-node.service \
    /etc/systemd/system/mediavps-worker.service
  rm -rf -- \
    /etc/systemd/system/timesmedia-node.service.d \
    "$NODE_CODE" "${NODE_CODE}.previous" \
    "$NODE_STATE" "$NODE_MEDIA" "$NODE_ENV" \
    /root/mediavps-node /mediavps-node /root/mediavps-storage
  systemctl daemon-reload
  ok "NODE anterior eliminado; WEB y otros proyectos no fueron modificados."
}

install_node(){
  local mode="${1:-}"
  [[ -z "$mode" || "$mode" == "--fresh" ]] || die "Uso: $0 node [--fresh]"
  [[ "$mode" != "--fresh" ]] || TM_FRESH_NODE=1
  log "Preparando TimesMedia NODE ${INSTALLER_VERSION}..."
  apt_install aria2 ca-certificates curl ffmpeg git openssl python3 python3-venv
  install -d -m 755 /opt /etc/timesmedia /srv/timesmedia

  # Authenticate and obtain a complete source checkout before deleting anything.
  atomic_code_install "$TM_NODE_REPO" "$NODE_CODE"
  local stage="$TM_STAGE"
  [[ -f "$stage/requirements.txt" && -f "$stage/.env.node.example" ]] || die "El repositorio NODE está incompleto."
  [[ -f "$stage/deploy/systemd/timesmedia-node.service" && -f "$stage/deploy/systemd/timesmedia-worker.service" ]] || die "Faltan unidades systemd del NODE."

  if [[ "$TM_FRESH_NODE" == 1 ]]; then
    fresh_node_reset
  fi

  ensure_user timesmedia-node "$NODE_STATE"
  secure_mkdir timesmedia-node 700 "$NODE_STATE"
  for d in cache posters fallback hls torrents aria2; do secure_mkdir timesmedia-node 700 "$NODE_STATE/$d"; done
  secure_mkdir timesmedia-node 750 "$NODE_MEDIA"

  chown -R timesmedia-node:timesmedia-node "$stage"

  if [[ ! -f "$NODE_ENV" ]]; then
    install -m 600 -o root -g root "$stage/.env.node.example" "$NODE_ENV"
    local token web_ip fs mem_kb cache cores trans
    token=$(openssl rand -hex 32); write_kv "$NODE_ENV" NODE_TOKEN "$token"; unset token
    web_ip="${TM_WEB_IP:-}"
    if [[ -z "$web_ip" ]]; then
      read -r -p "IP pública/privada del controlador WEB autorizada para 5100: " web_ip
    fi
    [[ "$web_ip" =~ ^[0-9A-Fa-f:.]+$ ]] || die "IP WEB inválida."
    write_kv "$NODE_ENV" TIMESMEDIA_WEB_IP "$web_ip"
    fs=$(findmnt -no FSTYPE --target "$NODE_MEDIA" 2>/dev/null || echo unknown)
    case "$fs" in ext4|xfs|btrfs) write_kv "$NODE_ENV" NODE_TORRENT_FILE_ALLOCATION falloc;; *) write_kv "$NODE_ENV" NODE_TORRENT_FILE_ALLOCATION none;; esac
    mem_kb=$(awk '/MemTotal/{print $2}' /proc/meminfo); cache=64M; (( mem_kb >= 4000000 )) && cache=128M
    write_kv "$NODE_ENV" NODE_TORRENT_DISK_CACHE "$cache"
    cores=$(nproc 2>/dev/null || echo 1); trans=1; (( cores >= 4 && mem_kb >= 6000000 )) && trans=2
    write_kv "$NODE_ENV" NODE_MAX_TRANSCODES "$trans"
    write_kv "$NODE_ENV" NODE_API_THREADS 16
    chmod 600 "$NODE_ENV"
  fi

  if [[ "$TM_FRESH_NODE" != 1 ]]; then
    legacy_node_migrate
    preflight_node_cutover_migration
    if service_active mediavps-node.service && [[ "${TM_LEGACY_MIGRATE:-0}" != 1 ]]; then
      warn "MediaVPS NODE sigue activo en 5100 y la migración fue omitida."
      warn "No tocaré el servicio ni el storage activo. Usa 'node --fresh' para reemplazarlo sin migrar."
      rm -rf -- "$stage"
      install_cli
      return 0
    fi
  fi
  systemctl stop timesmedia-node.service timesmedia-worker.service 2>/dev/null || true
  TM_NODE_CUTOVER_ACTIVE=1
  swap_code "$stage" "$NODE_CODE"
  chown -R timesmedia-node:timesmedia-node "$NODE_CODE"
  if ! python_venv_build_as timesmedia-node "$NODE_CODE"; then
    die "No se pudo construir el entorno Python del NODE en su ruta final."
  fi
  if ! python_module_check_as timesmedia-node "$NODE_CODE" gunicorn --version >/dev/null; then
    die "Gunicorn no es ejecutable desde el entorno final del NODE."
  fi
  install -m 644 "$NODE_CODE/deploy/systemd/timesmedia-node.service" /etc/systemd/system/timesmedia-node.service
  install -m 644 "$NODE_CODE/deploy/systemd/timesmedia-worker.service" /etc/systemd/system/timesmedia-worker.service
  systemctl daemon-reload

  if ! perform_node_cutover_migration; then
    systemctl stop timesmedia-node.service timesmedia-worker.service 2>/dev/null || true
    rollback_code "$NODE_CODE"
    rollback_node_legacy
    die "La migración del NODE falló; se restauró MediaVPS."
  fi
  local web_ip
  web_ip=$(sed -n 's/^TIMESMEDIA_WEB_IP=//p' "$NODE_ENV" | tail -n1)
  install -d -m 755 /etc/systemd/system/timesmedia-node.service.d
  cat > /etc/systemd/system/timesmedia-node.service.d/network.conf <<EOFNET
[Service]
IPAddressDeny=any
IPAddressAllow=127.0.0.0/8
IPAddressAllow=::1/128
IPAddressAllow=$web_ip
EOFNET
  chmod 644 /etc/systemd/system/timesmedia-node.service.d/network.conf
  systemctl daemon-reload
  if have ufw; then
    ufw --force delete allow 5100/tcp >/dev/null 2>&1 || true
    ufw --force delete allow 5100 >/dev/null 2>&1 || true
    ufw allow from "$web_ip" to any port 5100 proto tcp >/dev/null || true
    local bt_port
    bt_port=$(sed -n 's/^NODE_TORRENT_PORT=//p' "$NODE_ENV" | tail -n1); bt_port=${bt_port:-6883}
    ufw allow "$bt_port"/tcp >/dev/null || true
    ufw allow "$bt_port"/udp >/dev/null || true
    if ! ufw status | head -1 | grep -qi active; then
      warn "UFW está inactivo. Añadí reglas, pero NO lo habilité automáticamente para no bloquear SSH/u otros proyectos."
    fi
  else
    warn "UFW no está instalado; configura un firewall equivalente antes de exponer el NODE."
  fi

  if ! systemctl enable --now timesmedia-node.service timesmedia-worker.service; then
    systemctl stop timesmedia-node.service timesmedia-worker.service 2>/dev/null || true
    rollback_code "$NODE_CODE"; rollback_node_legacy
    die "NODE no inició; se intentó rollback al MediaVPS anterior."
  fi
  local health_token
  health_token=$(sed -n 's/^NODE_TOKEN=//p' "$NODE_ENV" | tail -n1)
  local healthy=0 i
  for ((i=1;i<=30;i++)); do
    if curl -fsS --max-time 3 -H "Authorization: Bearer $health_token" http://127.0.0.1:5100/v1/health >/dev/null 2>&1; then healthy=1; break; fi
    sleep 1
  done
  unset health_token
  if [[ "$healthy" != 1 ]]; then
    journalctl -u timesmedia-node.service -n 50 --no-pager >&2 || true
    systemctl stop timesmedia-node.service timesmedia-worker.service || true
    rollback_code "$NODE_CODE"; rollback_node_legacy
    die "Health check NODE falló; se ejecutó rollback."
  fi
  commit_node_legacy
  systemctl disable mediavps-node.service mediavps-worker.service >/dev/null 2>&1 || true
  install_cli
  ok "TimesMedia NODE instalado y saludable."
}

install_cli(){
  install -m 755 "$SCRIPT_DIR/timesmedia" /usr/local/sbin/timesmedia
  install -d -m 755 /usr/local/lib/timesmedia
  install -m 644 "$SCRIPT_DIR/lib/common.sh" /usr/local/lib/timesmedia/common.sh
  install -m 700 "$SCRIPT_DIR/install-timesmedia.sh" /usr/local/lib/timesmedia/install-timesmedia.sh
}

menu(){
  cat <<'MENU'

╔════════════════════════════════╗
║      TimesMedia Installer      ║
╠════════════════════════════════╣
║ 1. Instalar WEB desde cero     ║
║ 2. Instalar NODE desde cero    ║
║ 3. Instalar ambos desde cero   ║
║ 4. Actualizar / migrar WEB     ║
║ 5. Actualizar / migrar NODE    ║
║ 6. Security check              ║
║ 7. Salir                       ║
╚════════════════════════════════╝
MENU
  local choice; read -r -p "Opción: " choice
  case "$choice" in
    1) install_web --fresh;;
    2) install_node --fresh;;
    3) install_web --fresh; install_node --fresh;;
    4) install_web;;
    5) install_node;;
    6) install_cli; /usr/local/sbin/timesmedia security-check;;
    7) exit 0;;
    *) die "Opción inválida.";;
  esac
}

case "${1:-}" in
  web) install_web "${2:-}";;
  node) install_node "${2:-}";;
  all)
    [[ -z "${2:-}" || "${2:-}" == "--fresh" ]] || die "Uso: $0 all [--fresh]"
    install_web "${2:-}"
    install_node "${2:-}"
    ;;
  "") menu;;
  *) die "Uso: $0 [web [--fresh]|node [--fresh]|all [--fresh]]";;
esac
