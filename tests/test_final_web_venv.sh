#!/usr/bin/env bash
set -Eeuo pipefail

[[ ${EUID:-$(id -u)} -eq 0 ]] || { printf 'Ejecuta esta prueba como root.\n' >&2; exit 1; }

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"

TEST_CODE=$(mktemp -d /opt/timesmedia-web-venv-test.XXXXXX)
PRIVATE_CWD=$(mktemp -d /tmp/timesmedia-web-private-cwd.XXXXXX)
TEST_STATE=$(mktemp -d /tmp/timesmedia-web-state.XXXXXX)
TEST_ENV=$(mktemp /tmp/timesmedia-web-env.XXXXXX)
TEST_USER="tmwtest$$"

cleanup(){
  cd /
  userdel "$TEST_USER" >/dev/null 2>&1 || true
  rm -rf -- "$TEST_CODE" "$PRIVATE_CWD" "$TEST_STATE"
  rm -f -- "$TEST_ENV"
}
trap cleanup EXIT

useradd --system --home-dir "$TEST_STATE" --no-create-home --shell /usr/sbin/nologin "$TEST_USER"
printf 'Flask==3.1.3\ngunicorn==26.0.0\n' > "$TEST_CODE/requirements.txt"
printf 'from flask import Flask\napp = Flask(__name__)\n@app.get("/health")\ndef health(): return {"ok": True}\n' > "$TEST_CODE/app.py"
chown -R "$TEST_USER:$TEST_USER" "$TEST_CODE" "$TEST_STATE"
printf 'TIMESMEDIA_STATE_DIR=%s\n' "$TEST_STATE" > "$TEST_ENV"
chmod 600 "$TEST_ENV"

install -d -m 700 "$PRIVATE_CWD/repo"
cd "$PRIVATE_CWD/repo"

python_venv_build_as "$TEST_USER" "$TEST_CODE"
version=$(python_module_check_as "$TEST_USER" "$TEST_CODE" gunicorn --version)
[[ "$version" == 'gunicorn (version 26.0.0)' ]] || { printf 'Versión inesperada: %s\n' "$version" >&2; exit 1; }
(cd "$TEST_CODE" && runuser -u "$TEST_USER" -- "$TEST_CODE/.venv/bin/python" -c 'from app import app; assert app')
mapfile -t web_environment < <(sed -nE '/^[A-Za-z_][A-Za-z0-9_]*=/p' "$TEST_ENV")
(cd "$TEST_CODE" && runuser -u "$TEST_USER" -- env "${web_environment[@]}" "$TEST_CODE/.venv/bin/python" -c 'from app import app; assert app')

printf 'OK: WEB final venv works from inaccessible bootstrap cwd\n'
