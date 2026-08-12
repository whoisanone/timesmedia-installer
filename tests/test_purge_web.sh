#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
FIXTURE=$(mktemp -d /tmp/timesmedia-web-purge-fixture.XXXXXX)
AS_ROOT=()
[[ ${EUID:-$(id -u)} -eq 0 ]] || AS_ROOT=(sudo)
cleanup(){ "${AS_ROOT[@]}" rm -rf -- "$FIXTURE"; }
trap cleanup EXIT

mkdir -p \
  "$FIXTURE/etc/systemd/system/multi-user.target.wants" \
  "$FIXTURE/etc/timesmedia" \
  "$FIXTURE/opt/timesmedia-web" \
  "$FIXTURE/opt/.timesmedia-web.stage.123" \
  "$FIXTURE/var/lib/timesmedia-web" \
  "$FIXTURE/home/ubuntu/web/mediavps" \
  "$FIXTURE/home/ubuntu/web/posdesk" \
  "$FIXTURE/opt/timesmedia-node" \
  "$FIXTURE/var/lib/timesmedia-node" \
  "$FIXTURE/etc/cloudflared" \
  "$FIXTURE/usr/local/lib/timesmedia"

touch \
  "$FIXTURE/etc/systemd/system/timesmedia-web.service" \
  "$FIXTURE/etc/systemd/system/mediavps.service" \
  "$FIXTURE/etc/systemd/system/cloudflared.service" \
  "$FIXTURE/etc/timesmedia/web.env" \
  "$FIXTURE/etc/timesmedia/node.env" \
  "$FIXTURE/home/ubuntu/web/mediavps/DELETE_ME" \
  "$FIXTURE/home/ubuntu/web/posdesk/MUST_SURVIVE" \
  "$FIXTURE/opt/timesmedia-node/MUST_SURVIVE" \
  "$FIXTURE/var/lib/timesmedia-node/MUST_SURVIVE" \
  "$FIXTURE/etc/cloudflared/MUST_SURVIVE" \
  "$FIXTURE/usr/local/lib/timesmedia/MUST_SURVIVE"
ln -s ../timesmedia-web.service "$FIXTURE/etc/systemd/system/multi-user.target.wants/timesmedia-web.service"

"${AS_ROOT[@]}" env TM_PURGE_ROOT="$FIXTURE" bash "$ROOT/purge-web.sh" --yes

for removed in \
  opt/timesmedia-web \
  opt/.timesmedia-web.stage.123 \
  var/lib/timesmedia-web \
  home/ubuntu/web/mediavps \
  etc/timesmedia/web.env; do
  [[ ! -e "$FIXTURE/$removed" ]] || { printf 'No se eliminó %s\n' "$removed" >&2; exit 1; }
done

for preserved in \
  home/ubuntu/web/posdesk/MUST_SURVIVE \
  opt/timesmedia-node/MUST_SURVIVE \
  var/lib/timesmedia-node/MUST_SURVIVE \
  etc/timesmedia/node.env \
  etc/systemd/system/cloudflared.service \
  etc/cloudflared/MUST_SURVIVE \
  usr/local/lib/timesmedia/MUST_SURVIVE; do
  [[ -e "$FIXTURE/$preserved" ]] || { printf 'La purga tocó %s\n' "$preserved" >&2; exit 1; }
done

printf 'OK: WEB purge removes WEB and preserves NODE/cloudflared/other projects\n'
