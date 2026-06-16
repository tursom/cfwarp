#!/usr/bin/env bash
set -Eeuo pipefail

CFWARP_WARP_MODE="${CFWARP_WARP_MODE:-}"
CFWARP_ENABLE_FORWARDING="${CFWARP_ENABLE_FORWARDING:-true}"
CFWARP_ENABLE_IPV6_FORWARDING="${CFWARP_ENABLE_IPV6_FORWARDING:-false}"
CFWARP_HEALTHCHECK_INTERVAL="${CFWARP_HEALTHCHECK_INTERVAL:-30s}"
CFWARP_REMOTE_IPV4_CIDRS="${CFWARP_REMOTE_IPV4_CIDRS:-100.96.0.0/12}"

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
      die "Forwarding auto-enable needs permission to write this network namespace's sysctls. Keep NET_ADMIN on cfwarp, or set CFWARP_ENABLE_FORWARDING=false and manage forwarding yourself."
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
  if is_true "${CFWARP_ENABLE_IPV6_FORWARDING}"; then
    set_sysctl_if_present net.ipv6.conf.all.forwarding 1
    set_sysctl_if_present net.ipv6.conf.all.accept_ra 2
  else
    log "IPv6 forwarding auto-enable disabled by CFWARP_ENABLE_IPV6_FORWARDING=${CFWARP_ENABLE_IPV6_FORWARDING}"
  fi
}

sync_remote_mesh_routes() {
  local cidr

  if [[ -z "${CFWARP_REMOTE_IPV4_CIDRS//[[:space:],]/}" ]]; then
    log "Remote Mesh IPv4 route management disabled"
    return
  fi

  if ! ip link show CloudflareWARP >/dev/null 2>&1; then
    log "CloudflareWARP interface is not ready; skipping remote Mesh route sync"
    return
  fi

  for cidr in ${CFWARP_REMOTE_IPV4_CIDRS//,/ }; do
    if [[ ! "${cidr}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
      log "Skipping invalid remote Mesh IPv4 CIDR: ${cidr}"
      continue
    fi

    if ! ip route show "${cidr}" | grep -Fq "${cidr} dev CloudflareWARP"; then
      ip route replace "${cidr}" dev CloudflareWARP
      log "Route remote Mesh CIDR ${cidr} through CloudflareWARP"
    fi
  done
}

start_warp_service() {
  rm -f "${WARP_IPC_SOCKET}"
  log "Starting warp-svc"
  warp-svc &
  WARP_SVC_PID="$!"
}

warp_cli() {
  warp-cli --accept-tos "$@"
}

wait_for_warp_cli() {
  local max_attempts="${1:-30}"
  local attempt=1
  local status_output

  while (( attempt <= max_attempts )); do
    if status_output="$(warp_cli status 2>&1)"; then
      printf '%s\n' "${status_output}" >/tmp/cfwarp-status.out
      log "warp-cli is ready"
      return 0
    fi
    printf '%s\n' "${status_output}" >/tmp/cfwarp-status.out

    if warp_cli_status_indicates_ready "${status_output}"; then
      log "warp-cli is ready"
      return 0
    fi

    if [[ -S "${WARP_IPC_SOCKET}" ]] && ! grep -Eiq "${WARP_CLI_NOT_READY_RE}" <<<"${status_output}"; then
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
  warp_cli status 2>&1 || true
}

is_registered() {
  local status
  status="$(status_text)"

  if grep -Eiq "${REGISTRATION_MISSING_RE}" <<<"${status}"; then
    return 1
  fi

  if grep -Eiq "${WARP_CLI_NOT_READY_RE}" <<<"${status}"; then
    return 1
  fi

  if grep -Eiq 'connected|connecting|disconnected' <<<"${status}"; then
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
  warp_cli connector new "${CFWARP_CONNECTOR_TOKEN}"
}

configure_warp() {
  if [[ -n "${CFWARP_WARP_MODE}" ]]; then
    log "Setting WARP mode to ${CFWARP_WARP_MODE}"
    if ! warp_cli mode "${CFWARP_WARP_MODE}"; then
      log "Unable to set WARP mode to ${CFWARP_WARP_MODE}; continuing with the mode allowed by the Cloudflare policy"
    fi
  else
    log "Skipping WARP mode override"
  fi
}

connect_warp() {
  log "Connecting WARP"
  warp_cli connect
}

is_connected() {
  local status
  status="$(status_text)"
  grep -Eiq '^Status( update)?:[[:space:]]*Connected([[:space:]]|$)' <<<"${status}"
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
      warp_cli connect || true
    fi

    sync_remote_mesh_routes

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
  sync_remote_mesh_routes
  health_loop
}

main "$@"
