#!/usr/bin/env bash
set -Eeuo pipefail
OWNER=${TM_OWNER:-whoisanone}
REPO=${TM_INSTALLER_REPO:-timesmedia-installer}
BRANCH=${TM_BRANCH:-main}
TMP=$(mktemp -d /tmp/timesmedia-bootstrap.XXXXXX)
trap 'rm -rf -- "$TMP"' EXIT
command -v git >/dev/null 2>&1 || { echo 'Falta git (sudo apt install git).' >&2; exit 1; }
SSH_URL="git@github.com:${OWNER}/${REPO}.git"
HTTPS_URL="https://github.com/${OWNER}/${REPO}.git"
if timeout 10 git -c core.sshCommand='ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new' ls-remote "$SSH_URL" HEAD >/dev/null 2>&1; then
  git -c core.sshCommand='ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new' clone --depth 1 --branch "$BRANCH" "$SSH_URL" "$TMP/repo"
else
  read -r -s -p 'GitHub token Fine-grained (Contents: Read-only): ' TOKEN; printf '\n'
  [[ ${#TOKEN} -ge 20 ]] || { echo 'Token vacío/corto.' >&2; exit 1; }
  TOKEN_FILE="$TMP/token"; ASKPASS="$TMP/askpass"; chmod 700 "$TMP"; printf '%s' "$TOKEN" > "$TOKEN_FILE"; chmod 600 "$TOKEN_FILE"; unset TOKEN
  cat > "$ASKPASS" <<EOF
#!/usr/bin/env bash
case "\$1" in
  *Username*) printf '%s\\n' x-access-token ;;
  *Password*) cat '$TOKEN_FILE' ;;
  *) exit 1 ;;
esac
EOF
  chmod 700 "$ASKPASS"
  GIT_ASKPASS="$ASKPASS" GIT_TERMINAL_PROMPT=0 git -c credential.helper= clone --depth 1 --branch "$BRANCH" "$HTTPS_URL" "$TMP/repo"
fi
cd "$TMP/repo"
exec sudo ./install-timesmedia.sh "$@"
