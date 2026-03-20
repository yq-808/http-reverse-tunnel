#!/usr/bin/env bash
set -euo pipefail

timestamp_logs() {
  while IFS= read -r line || [[ -n "${line}" ]]; do
    printf '[%(%Y-%m-%d %H:%M:%S)T] %s\n' -1 "${line}"
  done
}

exec > >(timestamp_logs)
exec 2> >(timestamp_logs >&2)

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

is_enabled() {
  case "${1,,}" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

TUNNEL_SSH_USER="${TUNNEL_SSH_USER:-root}"
TUNNEL_SSH_HOST="${TUNNEL_SSH_HOST:-}"
TUNNEL_SSH_KEY_PATH_RAW="${TUNNEL_SSH_KEY_PATH:-$HOME/.ssh/id_ed25519}"
TUNNEL_SSH_KEY_PATH="$(expand_home_path "${TUNNEL_SSH_KEY_PATH_RAW}")"

TUNNEL_REMOTE_BIND_HOST="${TUNNEL_REMOTE_BIND_HOST:-127.0.0.1}"
TUNNEL_LOCAL_HOST="${TUNNEL_LOCAL_HOST:-127.0.0.1}"
TUNNEL_LOCAL_PORT="${TUNNEL_LOCAL_PORT:-8787}"
TUNNEL_REMOTE_PORT="${TUNNEL_REMOTE_PORT:-${TUNNEL_LOCAL_PORT}}"

TUNNEL_SERVER_ALIVE_INTERVAL="${TUNNEL_SERVER_ALIVE_INTERVAL:-30}"
TUNNEL_SERVER_ALIVE_COUNT_MAX="${TUNNEL_SERVER_ALIVE_COUNT_MAX:-3}"

# Health check uses remote -> tunneled app HTTP endpoint.
TUNNEL_HEALTH_ENABLED="${TUNNEL_HEALTH_ENABLED:-1}"
TUNNEL_HEALTH_PATH="${TUNNEL_HEALTH_PATH:-/healthz}"
TUNNEL_HEALTH_TIMEOUT="${TUNNEL_HEALTH_TIMEOUT:-5}"
TUNNEL_HEALTH_CHECK_INTERVAL="${TUNNEL_HEALTH_CHECK_INTERVAL:-15}"
TUNNEL_HEALTH_MAX_FAILURES="${TUNNEL_HEALTH_MAX_FAILURES:-3}"

TUNNEL_RECONNECT_DELAY="${TUNNEL_RECONNECT_DELAY:-2}"

if [[ -z "${TUNNEL_SSH_HOST}" ]]; then
  echo "Missing TUNNEL_SSH_HOST. Set it in .env." >&2
  exit 1
fi

if [[ "${TUNNEL_HEALTH_PATH}" != /* ]]; then
  TUNNEL_HEALTH_PATH="/${TUNNEL_HEALTH_PATH}"
fi

lock_root="${PROJECT_ROOT}/.run"
supervisor_lock_dir=""
supervisor_lock_pid_file=""

sanitize_lock_component() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'
}

lock_name="$(
  printf '%s__%s__%s__%s__%s__%s' \
    "$(sanitize_lock_component "${TUNNEL_SSH_USER}")" \
    "$(sanitize_lock_component "${TUNNEL_SSH_HOST}")" \
    "$(sanitize_lock_component "${TUNNEL_REMOTE_BIND_HOST}")" \
    "$(sanitize_lock_component "${TUNNEL_REMOTE_PORT}")" \
    "$(sanitize_lock_component "${TUNNEL_LOCAL_HOST}")" \
    "$(sanitize_lock_component "${TUNNEL_LOCAL_PORT}")"
)"
supervisor_lock_dir="${lock_root}/supervisor-${lock_name}.lock"
supervisor_lock_pid_file="${supervisor_lock_dir}/pid"

acquire_supervisor_lock() {
  local owner_pid=""

  mkdir -p "${lock_root}"

  if mkdir "${supervisor_lock_dir}" 2>/dev/null; then
    printf '%s\n' "$$" > "${supervisor_lock_pid_file}"
    return
  fi

  if [[ -f "${supervisor_lock_pid_file}" ]]; then
    owner_pid="$(cat "${supervisor_lock_pid_file}" 2>/dev/null || true)"
  fi

  if [[ -n "${owner_pid}" ]] && kill -0 "${owner_pid}" >/dev/null 2>&1; then
    echo "Another tunnel supervisor is already running (pid=${owner_pid}) for ${TUNNEL_SSH_USER}@${TUNNEL_SSH_HOST} ${TUNNEL_REMOTE_BIND_HOST}:${TUNNEL_REMOTE_PORT} -> ${TUNNEL_LOCAL_HOST}:${TUNNEL_LOCAL_PORT}. Exiting."
    exit 1
  fi

  echo "Found stale supervisor lock. Reclaiming lock..."
  rm -rf "${supervisor_lock_dir}" 2>/dev/null || true

  if mkdir "${supervisor_lock_dir}" 2>/dev/null; then
    printf '%s\n' "$$" > "${supervisor_lock_pid_file}"
    return
  fi

  echo "Failed to acquire supervisor lock at ${supervisor_lock_dir}." >&2
  exit 1
}

release_supervisor_lock() {
  local owner_pid=""

  if [[ -f "${supervisor_lock_pid_file}" ]]; then
    owner_pid="$(cat "${supervisor_lock_pid_file}" 2>/dev/null || true)"
  fi

  if [[ "${owner_pid}" == "$$" ]]; then
    rm -rf "${supervisor_lock_dir}" 2>/dev/null || true
  fi
}

ssh_base_args=(
  -i "${TUNNEL_SSH_KEY_PATH}"
  -o IdentitiesOnly=yes
  -o ExitOnForwardFailure=yes
  -o ServerAliveInterval="${TUNNEL_SERVER_ALIVE_INTERVAL}"
  -o ServerAliveCountMax="${TUNNEL_SERVER_ALIVE_COUNT_MAX}"
)

tunnel_pid=""
stopping="0"
cleaned_up="0"

start_tunnel() {
  ssh \
    "${ssh_base_args[@]}" \
    -N -T \
    -R "${TUNNEL_REMOTE_BIND_HOST}:${TUNNEL_REMOTE_PORT}:${TUNNEL_LOCAL_HOST}:${TUNNEL_LOCAL_PORT}" \
    "${TUNNEL_SSH_USER}@${TUNNEL_SSH_HOST}" &
  tunnel_pid="$!"

  echo "Tunnel started (pid=${tunnel_pid}): ${TUNNEL_REMOTE_BIND_HOST}:${TUNNEL_REMOTE_PORT} -> ${TUNNEL_LOCAL_HOST}:${TUNNEL_LOCAL_PORT}"
}

stop_tunnel() {
  if [[ -n "${tunnel_pid}" ]] && kill -0 "${tunnel_pid}" >/dev/null 2>&1; then
    kill "${tunnel_pid}" >/dev/null 2>&1 || true
    wait "${tunnel_pid}" 2>/dev/null || true
  fi
  tunnel_pid=""
}

remote_tunnel_health_check() {
  if ! is_enabled "${TUNNEL_HEALTH_ENABLED}"; then
    return 0
  fi

  ssh \
    "${ssh_base_args[@]}" \
    -o BatchMode=yes \
    -o ConnectTimeout=8 \
    "${TUNNEL_SSH_USER}@${TUNNEL_SSH_HOST}" \
    "bash -lc 'URL=\"http://${TUNNEL_REMOTE_BIND_HOST}:${TUNNEL_REMOTE_PORT}${TUNNEL_HEALTH_PATH}\"; if command -v curl >/dev/null 2>&1; then curl -fsS --max-time ${TUNNEL_HEALTH_TIMEOUT} \"\$URL\" >/dev/null; elif command -v wget >/dev/null 2>&1; then wget -q -T ${TUNNEL_HEALTH_TIMEOUT} -O - \"\$URL\" >/dev/null; else exec 3<>/dev/tcp/${TUNNEL_REMOTE_BIND_HOST}/${TUNNEL_REMOTE_PORT}; printf \"GET ${TUNNEL_HEALTH_PATH} HTTP/1.1\\r\\nHost: ${TUNNEL_REMOTE_BIND_HOST}\\r\\nConnection: close\\r\\n\\r\\n\" >&3; head -n 1 <&3 | grep -q 200; fi'" \
    >/dev/null 2>&1
}

cleanup() {
  if [[ "${cleaned_up}" == "1" ]]; then
    return
  fi
  cleaned_up="1"
  stopping="1"
  stop_tunnel
  release_supervisor_lock
}

acquire_supervisor_lock

trap cleanup EXIT INT TERM

echo "Starting reverse tunnel supervisor..."
echo "Remote SSH: ${TUNNEL_SSH_USER}@${TUNNEL_SSH_HOST}"
echo "Main forward: ${TUNNEL_REMOTE_BIND_HOST}:${TUNNEL_REMOTE_PORT} -> ${TUNNEL_LOCAL_HOST}:${TUNNEL_LOCAL_PORT}"
if is_enabled "${TUNNEL_HEALTH_ENABLED}"; then
  echo "Health check: http://${TUNNEL_REMOTE_BIND_HOST}:${TUNNEL_REMOTE_PORT}${TUNNEL_HEALTH_PATH}"
fi

while [[ "${stopping}" == "0" ]]; do
  start_tunnel

  failures="0"

  while [[ "${stopping}" == "0" ]]; do
    if ! kill -0 "${tunnel_pid}" >/dev/null 2>&1; then
      wait "${tunnel_pid}" 2>/dev/null || true
      echo "Tunnel process exited. Reconnecting..."
      break
    fi

    if is_enabled "${TUNNEL_HEALTH_ENABLED}"; then
      if remote_tunnel_health_check; then
        if (( failures > 0 )); then
          echo "Tunnel health check recovered after ${failures} failed attempt(s)."
        fi
        failures="0"
      else
        failures="$((failures + 1))"
        echo "Tunnel health check failed (${failures}/${TUNNEL_HEALTH_MAX_FAILURES})."

        if (( failures >= TUNNEL_HEALTH_MAX_FAILURES )); then
          echo "Health failure threshold reached. Restarting tunnel..."
          stop_tunnel
          break
        fi
      fi
    fi

    sleep "${TUNNEL_HEALTH_CHECK_INTERVAL}"
  done

  if [[ "${stopping}" == "1" ]]; then
    break
  fi

  sleep "${TUNNEL_RECONNECT_DELAY}"
done

cleanup
