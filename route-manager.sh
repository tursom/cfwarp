#!/usr/bin/env bash
set -Eeuo pipefail

CFWARP_CONTAINER_IPV4="${CFWARP_CONTAINER_IPV4:-172.30.0.2}"
CFWARP_BRIDGE_NAME="${CFWARP_BRIDGE_NAME:-cfwarp0}"
CFWARP_REMOTE_IPV4_CIDRS="${CFWARP_REMOTE_IPV4_CIDRS:-100.96.0.0/12}"
CFWARP_ROUTE_INTERVAL="${CFWARP_ROUTE_INTERVAL:-30s}"
CFWARP_MANAGE_DOCKER_USER_RULES="${CFWARP_MANAGE_DOCKER_USER_RULES:-true}"
MANAGED_BRIDGE_IF=""
SLEEP_PID=""
SHUTDOWN_REQUESTED=false

log() {
  printf '[cfwarp-route] %s\n' "$*"
}

is_ipv4_cidr() {
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]
}

is_ipv4_addr() {
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

validate_config() {
  local cidr

  if ! is_ipv4_addr "${CFWARP_CONTAINER_IPV4}"; then
    log "ERROR: invalid CFWARP_CONTAINER_IPV4=${CFWARP_CONTAINER_IPV4}"
    exit 1
  fi

  for cidr in ${CFWARP_REMOTE_IPV4_CIDRS//,/ }; do
    if ! is_ipv4_cidr "${cidr}"; then
      log "ERROR: invalid IPv4 CIDR in CFWARP_REMOTE_IPV4_CIDRS: ${cidr}"
      exit 1
    fi
  done
}

sync_routes() {
  local cidr

  for cidr in ${CFWARP_REMOTE_IPV4_CIDRS//,/ }; do
    ip route replace "${cidr}" via "${CFWARP_CONTAINER_IPV4}"
    log "Route ${cidr} via ${CFWARP_CONTAINER_IPV4}"
  done
}

cleanup_routes() {
  local cidr

  for cidr in ${CFWARP_REMOTE_IPV4_CIDRS//,/ }; do
    if ip route show "${cidr}" | grep -Fq "via ${CFWARP_CONTAINER_IPV4}"; then
      ip route del "${cidr}" via "${CFWARP_CONTAINER_IPV4}" 2>/dev/null || true
      log "Removed route ${cidr} via ${CFWARP_CONTAINER_IPV4}"
    fi
  done
}

bridge_interface() {
  local route

  route="$(ip route get "${CFWARP_CONTAINER_IPV4}" 2>/dev/null || true)"
  if [[ -z "${route}" || "${route}" == *" via "* ]]; then
    return 0
  fi

  printf '%s\n' "${route}" \
    | sed -n 's/.* dev \([^ ]*\).*/\1/p' \
    | head -n 1
}

nft_chain_exists() {
  nft list chain ip filter DOCKER-USER >/dev/null 2>&1
}

nft_rule_exists() {
  local pattern="$1"

  nft list chain ip filter DOCKER-USER 2>/dev/null | grep -Fq "${pattern}"
}

insert_docker_user_rule() {
  local rule="$1"
  local pattern="$2"

  if ! nft_rule_exists "${pattern}"; then
    nft insert rule ip filter DOCKER-USER ${rule}
    log "Installed DOCKER-USER rule: ${pattern}"
  fi
}

sync_docker_user_rules() {
  local bridge_if
  local cidr

  if [[ "${CFWARP_MANAGE_DOCKER_USER_RULES}" != "true" ]]; then
    log "DOCKER-USER rule management disabled"
    return
  fi

  if ! nft_chain_exists; then
    log "DOCKER-USER chain not found; skipping Docker bridge firewall rules"
    return
  fi

  bridge_if="$(bridge_interface)"
  if [[ -z "${bridge_if}" ]]; then
    log "Cannot resolve bridge interface for ${CFWARP_CONTAINER_IPV4}; skipping Docker bridge firewall rules"
    return
  fi
  MANAGED_BRIDGE_IF="${bridge_if}"

  for cidr in ${CFWARP_REMOTE_IPV4_CIDRS//,/ }; do
    insert_docker_user_rule \
      "oifname \"${bridge_if}\" ip daddr ${cidr} accept" \
      "oifname \"${bridge_if}\" ip daddr ${cidr}"
  done
}

delete_docker_user_rule() {
  local bridge_if="$1"
  local cidr="$2"
  local handle

  if [[ -z "${bridge_if}" ]] || ! nft_chain_exists; then
    return
  fi

  while read -r handle; do
    if [[ -n "${handle}" ]]; then
      nft delete rule ip filter DOCKER-USER handle "${handle}" 2>/dev/null || true
      log "Removed DOCKER-USER rule: oifname \"${bridge_if}\" ip daddr ${cidr} accept"
    fi
  done < <(
    nft --handle list chain ip filter DOCKER-USER 2>/dev/null \
      | awk -v bridge_if="${bridge_if}" -v cidr="${cidr}" '
          index($0, "oifname \"" bridge_if "\"") &&
          index($0, "ip daddr " cidr) &&
          index($0, "accept") &&
          match($0, /# handle [0-9]+/) {
            print $NF
          }'
  )
}

cleanup_docker_user_rules() {
  local bridge_if
  local cidr
  local detected_bridge_if
  local bridge_ifs=()

  if [[ "${CFWARP_MANAGE_DOCKER_USER_RULES}" != "true" ]]; then
    return
  fi

  detected_bridge_if="$(bridge_interface)"
  bridge_ifs=("${MANAGED_BRIDGE_IF}" "${detected_bridge_if}" "${CFWARP_BRIDGE_NAME}")

  for bridge_if in "${bridge_ifs[@]}"; do
    [[ -n "${bridge_if}" ]] || continue

    for cidr in ${CFWARP_REMOTE_IPV4_CIDRS//,/ }; do
      delete_docker_user_rule "${bridge_if}" "${cidr}"
    done
  done
}

cleanup() {
  local exit_code=$?

  trap - EXIT INT TERM
  set +e
  log "Cleaning up managed host routes and Docker rules"
  cleanup_routes
  cleanup_docker_user_rules
  exit "${exit_code}"
}

request_shutdown() {
  SHUTDOWN_REQUESTED=true

  if [[ -n "${SLEEP_PID}" ]]; then
    kill "${SLEEP_PID}" 2>/dev/null || true
  fi
}

wait_for_next_sync() {
  SLEEP_PID=""
  sleep "${CFWARP_ROUTE_INTERVAL}" &
  SLEEP_PID="$!"
  wait "${SLEEP_PID}" || true
  SLEEP_PID=""
}

main() {
  validate_config
  trap cleanup EXIT
  trap request_shutdown INT TERM

  log "Managing IPv4 routes for ${CFWARP_REMOTE_IPV4_CIDRS} via ${CFWARP_CONTAINER_IPV4}"

  while [[ "${SHUTDOWN_REQUESTED}" != "true" ]]; do
    sync_routes
    sync_docker_user_rules
    wait_for_next_sync
  done

  exit 0
}

main "$@"
