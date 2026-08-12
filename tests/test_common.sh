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
grep -Fq 'fresh_node_reset' "$install_script" || fail "Falta reset limpio de NODE"
grep -Fq 'web_ip="${TM_WEB_IP:-}"' "$install_script" || fail "Falta IP WEB no interactiva"

printf 'OK: common runtime regressions\n'
