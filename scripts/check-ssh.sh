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

if [[ -z "${TUNNEL_SSH_HOST}" ]]; then
  echo "Missing TUNNEL_SSH_HOST. Set it in .env." >&2
  exit 1
fi

echo "[1/3] ping ${TUNNEL_SSH_HOST}"
ping -c 3 "${TUNNEL_SSH_HOST}"

echo "[2/3] check TCP/22"
nc -zv -w 5 "${TUNNEL_SSH_HOST}" 22

echo "[3/3] non-interactive SSH auth check"
ssh -i "${TUNNEL_SSH_KEY_PATH}" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=8 "${TUNNEL_SSH_USER}@${TUNNEL_SSH_HOST}" 'echo connected'
