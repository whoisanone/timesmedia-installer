#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"

TEST_TMP=$(mktemp -d /tmp/timesmedia-common-test.XXXXXX)
trap 'rm -rf -- "$TEST_TMP"' EXIT

fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_file(){ [[ -f "$1" ]] || fail "Falta $1"; }
assert_missing(){ [[ ! -e "$1" ]] || fail "No debía existir $1"; }

# Updating an existing install must preserve the previous checkout and rollback it.
mkdir -p "$TEST_TMP/stage" "$TEST_TMP/target"
printf 'new\n' > "$TEST_TMP/stage/version"
printf 'old\n' > "$TEST_TMP/target/version"
swap_code "$TEST_TMP/stage" "$TEST_TMP/target"
[[ "$(cat "$TEST_TMP/target/version")" == new ]] || fail "swap no activó staging"
[[ "$(cat "$TEST_TMP/target.previous/version")" == old ]] || fail "swap no conservó versión anterior"
rollback_code "$TEST_TMP/target"
[[ "$(cat "$TEST_TMP/target/version")" == old ]] || fail "rollback no restauró versión anterior"
assert_missing "$TEST_TMP/target.previous"

# A failed first install has no previous checkout and must remove the failed target.
mkdir -p "$TEST_TMP/fresh-stage"
printf 'new\n' > "$TEST_TMP/fresh-stage/version"
swap_code "$TEST_TMP/fresh-stage" "$TEST_TMP/fresh-target"
assert_file "$TEST_TMP/fresh-target/version"
rollback_code "$TEST_TMP/fresh-target"
assert_missing "$TEST_TMP/fresh-target"

# A piped/non-interactive install must fail with an explicit message, not silently.
if (_tm_prepare_token_auth </dev/null) >"$TEST_TMP/auth.out" 2>"$TEST_TMP/auth.err"; then
  fail "El prompt de token aceptó stdin cerrado"
fi
grep -q 'No hay una terminal interactiva' "$TEST_TMP/auth.err" || fail "Falta error claro sin terminal"

# GIT_ASKPASS must live on an executable temporary filesystem. Ubuntu may
# mount /run with noexec, which previously made a valid token look invalid.
mkdir -p "$TEST_TMP/auth-tmp"
TM_AUTH_TMPDIR="$TEST_TMP/auth-tmp" _tm_prepare_token_auth <<<'timesmedia-test-token-1234567890'
auth_dir="$TM_AUTH_DIR"
[[ "$TM_ASKPASS" == "$TEST_TMP/auth-tmp"/timesmedia-auth.*/askpass ]] || fail "askpass no usa el temporal ejecutable"
[[ "$(stat -c '%a' "$TM_AUTH_DIR")" == 700 ]] || fail "Directorio auth no es 0700"
[[ "$(stat -c '%a' "$TM_TOKEN_FILE")" == 600 ]] || fail "Token temporal no es 0600"
[[ "$(stat -c '%a' "$TM_ASKPASS")" == 700 ]] || fail "askpass no es ejecutable"
[[ "$("$TM_ASKPASS" 'Username for https://github.com')" == x-access-token ]] || fail "askpass no entrega usuario"
[[ "$("$TM_ASKPASS" 'Password for https://github.com')" == timesmedia-test-token-1234567890 ]] || fail "askpass no entrega token"
_tm_cleanup_auth
assert_missing "$auth_dir"

# An interrupted previous run must not leave a full orphaned venv forever.
mkdir -p "$TEST_TMP/stages/.timesmedia-node.stage.999999999" "$TEST_TMP/stages/.timesmedia-node.stage.$$"
cleanup_stale_stages "$TEST_TMP/stages" timesmedia-node "$TEST_TMP/stages/.timesmedia-node.stage.$$"
assert_missing "$TEST_TMP/stages/.timesmedia-node.stage.999999999"
[[ -d "$TEST_TMP/stages/.timesmedia-node.stage.$$" ]] || fail "La limpieza eliminó el staging activo"

# Keep the curl-pipe terminal handoff covered by CI.
grep -Fq 'exec ./install-timesmedia.sh "$@" </dev/tty' "$ROOT/bootstrap.sh" || fail "bootstrap no reconecta /dev/tty"

# Venvs with console-script shebangs must be built at their final path.
install_script="$ROOT/install-timesmedia.sh"
if sed -n '/^install_node(){/,/^install_cli(){/p' "$install_script" | grep -Fq 'python3 -m venv "$stage/.venv"'; then
  fail "NODE todavía construye el venv en staging"
fi
swap_line=$(grep -nF 'swap_code "$stage" "$NODE_CODE"' "$install_script" | tail -n1 | cut -d: -f1)
venv_line=$(grep -nF 'python_venv_build_as timesmedia-node "$NODE_CODE"' "$install_script" | tail -n1 | cut -d: -f1)
[[ -n "$swap_line" && -n "$venv_line" && "$venv_line" -gt "$swap_line" ]] || fail "El venv NODE no se construye después del swap final"
grep -Fq 'node) install_node "${2:-}"' "$install_script" || fail "Falta routing de node --fresh"
grep -Fq 'apt_install aria2 ca-certificates curl ffmpeg git megatools openssl python3 python3-venv' "$install_script" || fail "NODE debe instalar soporte para enlaces públicos de MEGA"
grep -Fq 'fresh_node_reset' "$install_script" || fail "Falta reset limpio de NODE"
grep -Fq 'web_ip="${TM_WEB_IP:-}"' "$install_script" || fail "Falta IP WEB no interactiva"
grep -Fq 'python_module_check_as timesmedia-node "$NODE_CODE" gunicorn --version' "$install_script" || fail "La comprobación de Gunicorn no fija un cwd accesible"
web_swap_line=$(grep -nF 'swap_code "$stage" "$WEB_CODE"' "$install_script" | head -n1 | cut -d: -f1)
web_venv_line=$(grep -nF 'python_venv_build_as timesmedia-web "$WEB_CODE"' "$install_script" | head -n1 | cut -d: -f1)
[[ -n "$web_swap_line" && -n "$web_venv_line" && "$web_venv_line" -gt "$web_swap_line" ]] || fail "El venv WEB no se construye después del swap final"
grep -Fq 'web) install_web "${2:-}"' "$install_script" || fail "Falta routing de web --fresh"
grep -Fq 'fresh_web_reset' "$install_script" || fail "Falta reset limpio de WEB"
grep -Fq 'python_module_check_as timesmedia-web "$WEB_CODE" gunicorn --version' "$install_script" || fail "La comprobación WEB no usa el venv final"
grep -Fq "mapfile -t web_environment" "$install_script" || fail "La comprobación WEB intenta leer web.env como usuario sin privilegios"
grep -Fq 'wait_http http://127.0.0.1:5000/ 5' "$install_script" || fail "La instalación WEB no comprueba la portada"
grep -Fq 'INSTALLER_VERSION=$(<"$SCRIPT_DIR/VERSION")' "$install_script" || fail "La versión mostrada por el instalador sigue hardcodeada"
grep -Fq 'curl -fsS --max-time 4 http://127.0.0.1:5000/ >/dev/null' "$ROOT/timesmedia" || fail "timesmedia health no comprueba la portada"

# The persisted updater must include every relative dependency it needs. A
# previous layout copied common.sh one directory too high and omitted VERSION,
# so `timesmedia update` failed before it could update anything.
grep -Fq 'install -d -m 755 /usr/local/lib/timesmedia /usr/local/lib/timesmedia/lib' "$install_script" || fail "install_cli no crea el layout lib/ persistente"
grep -Fq 'install -m 644 "$SCRIPT_DIR/lib/common.sh" /usr/local/lib/timesmedia/lib/common.sh' "$install_script" || fail "install_cli no copia lib/common.sh donde lo consume el actualizador"
grep -Fq 'install -m 644 "$SCRIPT_DIR/VERSION" /usr/local/lib/timesmedia/VERSION' "$install_script" || fail "install_cli no copia VERSION para futuras actualizaciones"
grep -Fq 'source /usr/local/lib/timesmedia/lib/common.sh' "$ROOT/timesmedia" || fail "timesmedia no usa el layout persistente nuevo"

printf 'OK: common runtime regressions\n'
