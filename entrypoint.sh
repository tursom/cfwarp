#!/usr/bin/env bash
set -Eeuo pipefail

CFWARP_WARP_MODE="${CFWARP_WARP_MODE:-warp}"
CFWARP_ENABLE_FORWARDING="${CFWARP_ENABLE_FORWARDING:-true}"
CFWARP_HEALTHCHECK_INTERVAL="${CFWARP_HEALTHCHECK_INTERVAL:-30s}"

WARP_SVC_PID=""
WARP_IPC_SOCKET="/run/cloudflare-warp/warp_service"
REGISTRATION_MISSING_RE='registration[[:space:]_-]*missing|registration required|not registered|no registration'
WARP_CLI_NOT_READY_RE='unable to connect.*daemon|failed to connect.*daemon|connection refused|no such file|timed out'

log() {
  printf '[cfwarp] %s\n' "$*"
}

die() {
  log "ERROR: $*"
  exit 1
}

cleanup() {
  local code=$?

  if [[ -n "${WARP_SVC_PID}" ]] && kill -0 "${WARP_SVC_PID}" 2>/dev/null; then
    log "Stopping warp-svc"
    kill "${WARP_SVC_PID}" 2>/dev/null || true
    wait "${WARP_SVC_PID}" 2>/dev/null || true
  fi

  exit "${code}"
}

trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

is_true() {
  case "${1,,}" in
    1|true|yes|y|on) return 0 ;;
    *) return 1 ;;
  esac
}

require_tun() {
  [[ -c /dev/net/tun ]] || die "/dev/net/tun is missing. Run the container with --device /dev/net/tun."
}

preflight_registration_token() {
  if [[ -n "${CFWARP_CONNECTOR_TOKEN:-}" ]]; then
    return
  fi

  if find /var/lib/cloudflare-warp -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .; then
    return
  fi

  die "CFWARP_CONNECTOR_TOKEN is required for first-time Mesh connector registration"
}

set_sysctl_if_present() {
  local key="$1"
  local value="$2"
  local path="/proc/sys/${key//./\/}"
  local current
  local output

  if [[ -e "${path}" ]]; then
    current="$(cat "${path}" 2>/dev/null || true)"
    if [[ "${current}" == "${value}" ]]; then
      log "${key} is already ${value}"
      return
    fi

    if output="$(sysctl -w "${key}=${value}" 2>&1)"; then
      log "Set ${key}=${value}"
    else
      log "Failed to set ${key}=${value}: ${output}"
      die "Forwarding auto-enable needs permission to write host network sysctls. Run with privileged: true, or set host sysctls manually and set CFWARP_ENABLE_FORWARDING=false."
    fi
  else
    log "Skipped ${key}; ${path} does not exist in this network namespace"
  fi
}

enable_forwarding() {
  if ! is_true "${CFWARP_ENABLE_FORWARDING}"; then
    log "Forwarding auto-enable disabled by CFWARP_ENABLE_FORWARDING=${CFWARP_ENABLE_FORWARDING}"
    return
  fi

  set_sysctl_if_present net.ipv4.ip_forward 1
  set_sysctl_if_present net.ipv6.conf.all.forwarding 1
  set_sysctl_if_present net.ipv6.conf.all.accept_ra 2
}

start_warp_service() {
  log "Starting warp-svc"
  warp-svc &
  WARP_SVC_PID="$!"
}

wait_for_warp_cli() {
  local max_attempts="${1:-30}"
  local attempt=1
  local status_output

  while (( attempt <= max_attempts )); do
    if status_output="$(warp-cli status 2>&1)"; then
      printf '%s\n' "${status_output}" >/tmp/cfwarp-status.out
      log "warp-cli is ready"
      return 0
    fi
    printf '%s\n' "${status_output}" >/tmp/cfwarp-status.out

    if warp_cli_status_indicates_ready "${status_output}"; then
      log "warp-cli is ready"
      return 0
    fi

    if [[ -S "${WARP_IPC_SOCKET}" ]]; then
      log "warp-cli IPC socket is ready"
      return 0
    fi

    if ! kill -0 "${WARP_SVC_PID}" 2>/dev/null; then
      cat /tmp/cfwarp-status.out >&2 || true
      die "warp-svc exited before warp-cli became ready"
    fi

    log "Waiting for warp-svc (${attempt}/${max_attempts})"
    sleep 1
    attempt=$((attempt + 1))
  done

  cat /tmp/cfwarp-status.out >&2 || true
  die "Timed out waiting for warp-cli"
}

warp_cli_status_indicates_ready() {
  local status="$1"

  if grep -Eiq "${REGISTRATION_MISSING_RE}" <<<"${status}"; then
    return 0
  fi

  if grep -Eiq "${WARP_CLI_NOT_READY_RE}" <<<"${status}"; then
    return 1
  fi

  grep -Eiq 'status|connected|connecting|disconnected|unable' <<<"${status}"
}

status_text() {
  warp-cli status 2>&1 || true
}

is_registered() {
  local status
  status="$(status_text)"

  if grep -Eiq "${REGISTRATION_MISSING_RE}" <<<"${status}"; then
    return 1
  fi

  if grep -Eiq 'connected|connecting|disconnected|connection' <<<"${status}"; then
    return 0
  fi

  return 1
}

ensure_registered() {
  if is_registered; then
    log "Existing WARP registration found"
    return
  fi

  [[ -n "${CFWARP_CONNECTOR_TOKEN:-}" ]] || die "CFWARP_CONNECTOR_TOKEN is required for first-time Mesh connector registration"

  log "Registering Mesh connector"
  warp-cli connector new "${CFWARP_CONNECTOR_TOKEN}"
}

configure_warp() {
  if [[ -n "${CFWARP_WARP_MODE}" ]]; then
    log "Setting WARP mode to ${CFWARP_WARP_MODE}"
    warp-cli mode "${CFWARP_WARP_MODE}"
  fi
}

connect_warp() {
  log "Connecting WARP"
  warp-cli connect
}

is_connected() {
  local status
  status="$(status_text)"
  grep -Eiq 'status:[[:space:]]*connected|connected' <<<"${status}"
}

health_loop() {
  while true; do
    if ! kill -0 "${WARP_SVC_PID}" 2>/dev/null; then
      die "warp-svc exited unexpectedly"
    fi

    local status
    status="$(status_text)"
    printf '%s\n' "${status}"

    if ! is_connected; then
      log "WARP is not connected; retrying connect"
      warp-cli connect || true
    fi

    sleep "${CFWARP_HEALTHCHECK_INTERVAL}"
  done
}

main() {
  preflight_registration_token
  require_tun
  enable_forwarding
  start_warp_service
  wait_for_warp_cli
  ensure_registered
  configure_warp
  connect_warp
  health_loop
}

main "$@"
