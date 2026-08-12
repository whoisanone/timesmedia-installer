#!/usr/bin/env bash
set -Eeuo pipefail

TM_OWNER="${TM_OWNER:-whoisanone}"
TM_WEB_REPO="${TM_WEB_REPO:-timesmedia-web}"
TM_NODE_REPO="${TM_NODE_REPO:-timesmedia-node}"
TM_BRANCH="${TM_BRANCH:-main}"
TM_BACKUP_DIR="${TM_BACKUP_DIR:-/var/backups/timesmedia}"

log(){ printf '\033[1;36m[TimesMedia]\033[0m %s\n' "$*"; }
ok(){ printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die(){ printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }
need_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Ejecuta este comando con sudo/root."; }
have(){ command -v "$1" >/dev/null 2>&1; }
confirm(){ local prompt="${1:-Continuar?}" answer; read -r -p "$prompt [y/N]: " answer; [[ "$answer" =~ ^[Yy]$ ]]; }

apt_install(){
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y --no-install-recommends "$@"
}

ensure_user(){
  local user="$1" home="$2"
  if ! id "$user" >/dev/null 2>&1; then
    useradd --system --home-dir "$home" --shell /usr/sbin/nologin "$user"
  fi
}

secure_mkdir(){ local owner="$1" mode="$2" path="$3"; install -d -m "$mode" -o "$owner" -g "$owner" "$path"; }

_tm_cleanup_auth(){
  [[ -n "${TM_TOKEN_FILE:-}" ]] && rm -f -- "$TM_TOKEN_FILE" || true
  [[ -n "${TM_ASKPASS:-}" ]] && rm -f -- "$TM_ASKPASS" || true
  TM_TOKEN_FILE=""; TM_ASKPASS=""
}

_tm_cleanup(){
  _tm_cleanup_auth
  if [[ -n "${TM_STAGE:-}" && -d "${TM_STAGE:-}" ]]; then
    rm -rf -- "$TM_STAGE" || true
  fi
}

_tm_prepare_token_auth(){
  local token
  if ! read -r -s -p "GitHub token (Fine-grained, Contents: Read-only): " token; then
    printf '\n'
    die "No hay una terminal interactiva para leer el token de GitHub."
  fi
  printf '\n'
  [[ ${#token} -ge 20 ]] || die "Token demasiado corto o vacío."
  TM_TOKEN_FILE=$(mktemp /run/timesmedia-gh-token.XXXXXX)
  TM_ASKPASS=$(mktemp /run/timesmedia-askpass.XXXXXX)
  chmod 600 "$TM_TOKEN_FILE"; printf '%s' "$token" > "$TM_TOKEN_FILE"; unset token
  cat > "$TM_ASKPASS" <<EOFASK
#!/usr/bin/env bash
case "\$1" in
  *Username*) printf '%s\\n' 'x-access-token' ;;
  *Password*) cat '$TM_TOKEN_FILE' ;;
  *) exit 1 ;;
esac
EOFASK
  chmod 700 "$TM_ASKPASS"
}

clone_private_repo(){
  local repo="$1" dest="$2"
  rm -rf -- "$dest"
  local ssh_url="git@github.com:${TM_OWNER}/${repo}.git"
  local https_url="https://github.com/${TM_OWNER}/${repo}.git"
  log "Obteniendo ${TM_OWNER}/${repo}..."
  if timeout 10 git -c core.sshCommand='ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new' ls-remote "$ssh_url" HEAD >/dev/null 2>&1; then
    git -c core.sshCommand='ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new' clone --depth 1 --branch "$TM_BRANCH" "$ssh_url" "$dest"
    return
  fi
  _tm_prepare_token_auth
  if ! GIT_ASKPASS="$TM_ASKPASS" GIT_TERMINAL_PROMPT=0 git -c credential.helper= clone --depth 1 --branch "$TM_BRANCH" "$https_url" "$dest"; then
    _tm_cleanup_auth
    die "No se pudo clonar el repositorio privado."
  fi
  _tm_cleanup_auth
}

TM_STAGE=""
atomic_code_install(){
  local repo="$1" target="$2" parent bundled_root bundled
  parent=$(dirname "$target")
  TM_STAGE="${parent}/.$(basename "$target").stage.$$"
  bundled_root="${TM_PAYLOAD_ROOT:-${SCRIPT_DIR:-}/payload}"
  bundled="${bundled_root%/}/$repo"
  rm -rf -- "$TM_STAGE"
  if [[ -n "$bundled_root" && -d "$bundled" ]]; then
    log "Usando payload verificado incluido para ${repo}."
    install -d -m 755 "$TM_STAGE"
    cp -a "$bundled/." "$TM_STAGE/"
  else
    clone_private_repo "$repo" "$TM_STAGE"
  fi
  rm -rf -- "$TM_STAGE/.git" "$TM_STAGE/__pycache__"
  find "$TM_STAGE" -type d -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null || true
  find "$TM_STAGE" -type f -name '*.pyc' -delete 2>/dev/null || true
}

python_venv_build(){
  local code="$1"
  python3 -m venv "$code/.venv"
  "$code/.venv/bin/python" -m pip install --upgrade pip setuptools wheel
  "$code/.venv/bin/pip" install --requirement "$code/requirements.txt"
  "$code/.venv/bin/python" -m compileall -q "$code"
}

swap_code(){
  local stage="$1" target="$2" backup
  backup="${target}.previous"
  rm -rf -- "$backup"
  [[ -d "$target" ]] && mv "$target" "$backup"
  mv "$stage" "$target"
}

rollback_code(){
  local target="$1" backup
  backup="${target}.previous"
  rm -rf -- "$target"
  [[ ! -d "$backup" ]] || mv "$backup" "$target"
}

write_kv(){
  local file="$1" key="$2" value="$3"
  if grep -qE "^${key}=" "$file" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$file"
  else
    printf '%s=%s\n' "$key" "$value" >> "$file"
  fi
}

service_active(){ systemctl is-active --quiet "$1" 2>/dev/null; }
service_exists(){ systemctl cat "$1" >/dev/null 2>&1; }

wait_http(){
  local url="$1" tries="${2:-30}" i
  for ((i=1;i<=tries;i++)); do
    if curl -fsS --max-time 3 "$url" >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  return 1
}

backup_stamp(){ date -u +%Y%m%dT%H%M%SZ; }
