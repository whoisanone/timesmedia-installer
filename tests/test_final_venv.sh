#!/usr/bin/env bash
set -Eeuo pipefail

[[ ${EUID:-$(id -u)} -eq 0 ]] || { printf 'Ejecuta esta prueba como root.\n' >&2; exit 1; }

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"

TEST_CODE=$(mktemp -d /opt/timesmedia-venv-test.XXXXXX)
PRIVATE_CWD=$(mktemp -d /tmp/timesmedia-private-cwd.XXXXXX)
TEST_USER="tmvtest$$"

cleanup(){
  cd /
  userdel "$TEST_USER" >/dev/null 2>&1 || true
  rm -rf -- "$TEST_CODE" "$PRIVATE_CWD"
}
trap cleanup EXIT

useradd --system --home-dir "$TEST_CODE" --no-create-home --shell /usr/sbin/nologin "$TEST_USER"
printf 'gunicorn==26.0.0\n' > "$TEST_CODE/requirements.txt"
chown -R "$TEST_USER:$TEST_USER" "$TEST_CODE"

# Reproduce the bootstrap layout: root can enter it, the service user cannot.
install -d -m 700 "$PRIVATE_CWD/repo"
cd "$PRIVATE_CWD/repo"

python_venv_build_as "$TEST_USER" "$TEST_CODE"
version=$(python_module_check_as "$TEST_USER" "$TEST_CODE" gunicorn --version)
[[ "$version" == 'gunicorn (version 26.0.0)' ]] || { printf 'Versión inesperada: %s\n' "$version" >&2; exit 1; }

printf 'OK: final venv works from inaccessible bootstrap cwd\n'
