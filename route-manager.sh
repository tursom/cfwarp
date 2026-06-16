#!/usr/bin/env bash
set -Eeuo pipefail

CFWARP_CONTAINER_IPV4="${CFWARP_CONTAINER_IPV4:-172.30.0.2}"
CFWARP_REMOTE_IPV4_CIDRS="${CFWARP_REMOTE_IPV4_CIDRS:-100.96.0.0/12}"
CFWARP_ROUTE_INTERVAL="${CFWARP_ROUTE_INTERVAL:-30s}"
CFWARP_MANAGE_DOCKER_USER_RULES="${CFWARP_MANAGE_DOCKER_USER_RULES:-true}"

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

bridge_interface() {
  ip route get "${CFWARP_CONTAINER_IPV4}" \
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

  for cidr in ${CFWARP_REMOTE_IPV4_CIDRS//,/ }; do
    insert_docker_user_rule \
      "oifname \"${bridge_if}\" ip daddr ${cidr} accept" \
      "oifname \"${bridge_if}\" ip daddr ${cidr}"
  done
}

main() {
  validate_config
  log "Managing IPv4 routes for ${CFWARP_REMOTE_IPV4_CIDRS} via ${CFWARP_CONTAINER_IPV4}"

  while true; do
    sync_routes
    sync_docker_user_rules
    sleep "${CFWARP_ROUTE_INTERVAL}"
  done
}

main "$@"
