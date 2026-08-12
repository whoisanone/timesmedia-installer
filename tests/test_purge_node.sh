#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
FIXTURE=$(mktemp -d /tmp/timesmedia-purge-fixture.XXXXXX)
AS_ROOT=()
[[ ${EUID:-$(id -u)} -eq 0 ]] || AS_ROOT=(sudo)
cleanup(){ "${AS_ROOT[@]}" rm -rf -- "$FIXTURE"; }
trap cleanup EXIT

mkdir -p \
  "$FIXTURE/etc/systemd/system/multi-user.target.wants" \
  "$FIXTURE/etc/timesmedia" \
  "$FIXTURE/opt/timesmedia-node" \
  "$FIXTURE/opt/.timesmedia-node.stage.123" \
  "$FIXTURE/var/lib/timesmedia-node" \
  "$FIXTURE/srv/timesmedia/media" \
  "$FIXTURE/root/mediavps-node" \
  "$FIXTURE/root/mediavps-storage" \
  "$FIXTURE/home/ubuntu/mediavps-node" \
  "$FIXTURE/home/ubuntu/mediavps-storage" \
  "$FIXTURE/home/ubuntu/web/mediavps" \
  "$FIXTURE/usr/local/lib/timesmedia"

touch \
  "$FIXTURE/etc/systemd/system/timesmedia-node.service" \
  "$FIXTURE/etc/systemd/system/mediavps-node.service" \
  "$FIXTURE/etc/timesmedia/node.env" \
  "$FIXTURE/etc/timesmedia/web.env" \
  "$FIXTURE/home/ubuntu/web/mediavps/MUST_SURVIVE" \
  "$FIXTURE/usr/local/lib/timesmedia/MUST_SURVIVE"
ln -s ../timesmedia-node.service "$FIXTURE/etc/systemd/system/multi-user.target.wants/timesmedia-node.service"

"${AS_ROOT[@]}" env TM_PURGE_ROOT="$FIXTURE" bash "$ROOT/purge-node.sh" --yes

for removed in \
  opt/timesmedia-node \
  opt/.timesmedia-node.stage.123 \
  var/lib/timesmedia-node \
  srv/timesmedia \
  root/mediavps-node \
  root/mediavps-storage \
  home/ubuntu/mediavps-node \
  home/ubuntu/mediavps-storage \
  etc/timesmedia/node.env; do
  [[ ! -e "$FIXTURE/$removed" ]] || { printf 'No se eliminó %s\n' "$removed" >&2; exit 1; }
done

[[ -f "$FIXTURE/etc/timesmedia/web.env" ]] || { printf 'Se eliminó web.env\n' >&2; exit 1; }
[[ -f "$FIXTURE/home/ubuntu/web/mediavps/MUST_SURVIVE" ]] || { printf 'Se tocó MediaVPS WEB\n' >&2; exit 1; }
[[ -f "$FIXTURE/usr/local/lib/timesmedia/MUST_SURVIVE" ]] || { printf 'Se eliminó el CLI compartido con WEB\n' >&2; exit 1; }

printf 'OK: purge removes NODE and preserves WEB\n'
