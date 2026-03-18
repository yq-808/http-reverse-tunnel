#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

if [[ -f "${PROJECT_ROOT}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${PROJECT_ROOT}/.env"
  set +a
fi

expand_home_path() {
  local raw="$1"
  if [[ "${raw}" == "~/"* ]]; then
    printf '%s/%s' "${HOME}" "${raw#~/}"
    return
  fi
  printf '%s' "${raw}"
}

TUNNEL_SSH_USER="${TUNNEL_SSH_USER:-root}"
TUNNEL_SSH_HOST="${TUNNEL_SSH_HOST:-}"
TUNNEL_SSH_KEY_PATH_RAW="${TUNNEL_SSH_KEY_PATH:-$HOME/.ssh/id_ed25519}"
TUNNEL_SSH_KEY_PATH="$(expand_home_path "${TUNNEL_SSH_KEY_PATH_RAW}")"

TUNNEL_REMOTE_BIND_HOST="${TUNNEL_REMOTE_BIND_HOST:-127.0.0.1}"
TUNNEL_REMOTE_PORT="${TUNNEL_REMOTE_PORT:-18787}"
TUNNEL_LOCAL_HOST="${TUNNEL_LOCAL_HOST:-127.0.0.1}"
TUNNEL_LOCAL_PORT="${TUNNEL_LOCAL_PORT:-8787}"
TUNNEL_SERVER_ALIVE_INTERVAL="${TUNNEL_SERVER_ALIVE_INTERVAL:-30}"
TUNNEL_SERVER_ALIVE_COUNT_MAX="${TUNNEL_SERVER_ALIVE_COUNT_MAX:-3}"

if [[ -z "${TUNNEL_SSH_HOST}" ]]; then
  echo "Missing TUNNEL_SSH_HOST. Set it in .env." >&2
  exit 1
fi

echo "Opening reverse tunnel: ${TUNNEL_SSH_USER}@${TUNNEL_SSH_HOST}:${TUNNEL_REMOTE_BIND_HOST}:${TUNNEL_REMOTE_PORT} -> ${TUNNEL_LOCAL_HOST}:${TUNNEL_LOCAL_PORT}"
echo "On remote host, call: curl http://${TUNNEL_REMOTE_BIND_HOST}:${TUNNEL_REMOTE_PORT}/healthz"

exec ssh \
  -i "${TUNNEL_SSH_KEY_PATH}" \
  -o IdentitiesOnly=yes \
  -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval="${TUNNEL_SERVER_ALIVE_INTERVAL}" \
  -o ServerAliveCountMax="${TUNNEL_SERVER_ALIVE_COUNT_MAX}" \
  -N -T \
  -R "${TUNNEL_REMOTE_BIND_HOST}:${TUNNEL_REMOTE_PORT}:${TUNNEL_LOCAL_HOST}:${TUNNEL_LOCAL_PORT}" \
  "${TUNNEL_SSH_USER}@${TUNNEL_SSH_HOST}"
