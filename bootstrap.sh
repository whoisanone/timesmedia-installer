#!/usr/bin/env bash
set -Eeuo pipefail

OWNER=${TM_OWNER:-whoisanone}
REPO=${TM_INSTALLER_REPO:-timesmedia-installer}
BRANCH=${TM_BRANCH:-main}
TMP=$(mktemp -d /tmp/timesmedia-bootstrap.XXXXXX)
trap 'rm -rf -- "$TMP"' EXIT

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo 'Ejecuta el instalador con sudo/root.' >&2
  exit 1
fi

if ! command -v git >/dev/null 2>&1; then
  echo '[TimesMedia] Instalando git...'
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends git ca-certificates
fi

HTTPS_URL="https://github.com/${OWNER}/${REPO}.git"
echo '[TimesMedia] Descargando instalador...'
git -c credential.helper= clone --quiet --depth 1 --branch "$BRANCH" "$HTTPS_URL" "$TMP/repo"

cd "$TMP/repo"
chmod +x ./install-timesmedia.sh

# `curl | bash` consumes stdin with the bootstrap itself. Reconnect the real
# terminal before the interactive installer asks for tokens, IPs or passwords.
if [[ -c /dev/tty ]] && { : </dev/tty; } 2>/dev/null; then
  exec ./install-timesmedia.sh "$@" </dev/tty
fi
exec ./install-timesmedia.sh "$@"
