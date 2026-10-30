#!/usr/bin/env bash
set -Eeuo pipefail

# This script sets up local split-DNS for the `rezakara.demo` domain.
# We keep `systemd-resolved` as the system resolver (`/etc/resolv.conf` -> 127.0.0.53),
# but point it to `dnsmasq` on 127.0.0.1 for actual upstream resolution.
#
# `dnsmasq` is used because it can reliably do per-domain forwarding:
#   - `*.rezakara.demo` -> PowerDNS on 127.0.0.1:5300
#   - everything else   -> normal public DNS upstreams
#
# We use this design because `systemd-resolved` does not handle custom-port split DNS
# for PowerDNS on :5300 as reliably as `dnsmasq` does.
# Final flow:
#   apps -> systemd-resolved -> dnsmasq -> PowerDNS/public DNS


DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=libs/common.sh
source "$DIR/libs/common.sh"
# shellcheck source=libs/utils.sh
source "$DIR/libs/utils.sh"

# PowerDNS configuration
POWERDNS_MAJOR="5.0"
POWERDNS_IMAGE_TAG="5.0.0"
POWERDNS_IMAGE_NAME="pdns-auth-50"
POWERDNS_IMAGE_BRANCH="auth-${POWERDNS_MAJOR}.x"
POWERDNS_COMPOSE_FILE="${DIR}/../powerdns/docker-compose.yaml"
VAULT_BASE_PATH="local/powerdns"
VAULT_DB_PATH="$VAULT_BASE_PATH/db"
VAULT_API_PATH="$VAULT_BASE_PATH/api"

# DNSMASQ configuration
DNSMASQ_CONF="/etc/dnsmasq.d/rezakara.conf"
DNSMASQ_MAIN_CONF="/etc/dnsmasq.conf"
DNSMASQ_EXPECTED_CONF=$(cat <<'EOF'
# Rezakara DNS config
listen-address=127.0.0.1
server=/rezakara.demo/127.0.0.1#5300
# Prevent circular resolution through system resolver
no-resolv
server=1.1.1.1
server=8.8.4.4
EOF
)


# -----------------------------------------------------
# Global error handler to provide better context on failures
# -----------------------------------------------------
on_error() {
  local exit_code=$?
  err "Command failed at line $1: $2"
  exit "$exit_code"
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR


# -----------------------------------------------------
# Verifies a required systemd service exists on the machine before the script continues
# -----------------------------------------------------
require_service_unit() {
  local unit="$1"
  systemctl list-unit-files "${unit}.service" 2>/dev/null | grep -q "^${unit}\.service" || {
    err "Required systemd service not installed: ${unit}.service"
    exit 1
  }
}


# -----------------------------------------------------
# Ensures systemd-resolved is running and warns if /etc/resolv.conf 
# is not using its expected stub resolver setup.
# -----------------------------------------------------
ensure_systemd_resolved_running() {
  if ! sudo systemctl is-active --quiet systemd-resolved; then
    log "Starting systemd-resolved..."
    sudo systemctl enable --now systemd-resolved
  fi

  if [[ -L /etc/resolv.conf ]]; then
    if [[ "$(readlink -f /etc/resolv.conf)" != "/run/systemd/resolve/stub-resolv.conf" ]]; then
      warn "/etc/resolv.conf is symlinked, but not to systemd-resolved stub"
    fi
  else
    warn "/etc/resolv.conf is not a symlink; system DNS may be managed differently"
  fi

  ok "systemd-resolved is active"
}


# -----------------------------------------------------
# Flush DNS cache for systemd-resolved or dnsmasq depending on which is active
# -----------------------------------------------------
flush_dns_cache() {
  log "Flushing DNS cache..."

  if sudo systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    if command -v resolvectl >/dev/null 2>&1; then
      sudo resolvectl flush-caches || warn "Failed to flush with resolvectl"
      ok "DNS cache flushed (systemd-resolved)"
      return 0
    fi

    if command -v systemd-resolve >/dev/null 2>&1; then
      sudo systemd-resolve --flush-caches || warn "Failed to flush with systemd-resolve"
      ok "DNS cache flushed (systemd-resolve)"
      return 0
    fi
  fi

  if sudo systemctl is-active --quiet dnsmasq 2>/dev/null; then
    restart_dnsmasq
    ok "dnsmasq refreshed"
    return 0
  fi

  warn "No active DNS cache service found; skipping flush"
}


# -----------------------------------------------------
# Restart dnsmasq service and verify it's running
# -----------------------------------------------------
restart_dnsmasq() {
  log "Validating dnsmasq configuration..."
  sudo dnsmasq --test --conf-file=/etc/dnsmasq.conf >/dev/null

  log "Restarting dnsmasq..."
  sudo systemctl restart dnsmasq

  sudo systemctl is-active --quiet dnsmasq || {
    err "dnsmasq is not running after restart"
    exit 1
  }
}


# -----------------------------------------------------
# Load secrets from Vault and export as environment variables
# -----------------------------------------------------
load_powerdns_secrets() {
  log "Loading secrets from Vault..."

  POSTGRES_DB="pdns"
  POSTGRES_USER="$(vault kv get -field=user "$VAULT_DB_PATH")"
  POSTGRES_PASSWORD="$(vault kv get -field=password "$VAULT_DB_PATH")"
  PDNS_API_KEY="$(vault kv get -field=key "$VAULT_API_PATH")"

  [[ -n "$POSTGRES_USER" ]] || { err "DB user missing"; exit 1; }
  [[ -n "$POSTGRES_PASSWORD" ]] || { err "DB password missing"; exit 1; }
  [[ -n "$PDNS_API_KEY" ]] || { err "API key missing"; exit 1; }

  export POSTGRES_DB
  export POSTGRES_USER
  export POSTGRES_PASSWORD
  export PDNS_API_KEY

  ok "Secrets loaded and exported"
}


# -----------------------------------------------------
# Start PowerDNS stack using Docker Compose
# -----------------------------------------------------
start_compose() {
  local schema_file="${DIR}/../powerdns/schema.pgsql.sql"
  local schema_url="https://raw.githubusercontent.com/PowerDNS/pdns/rel/${POWERDNS_IMAGE_BRANCH}/modules/gpgsqlbackend/schema.pgsql.sql"

  export POWERDNS_IMAGE_NAME
  export POWERDNS_IMAGE_TAG

  log "Starting PowerDNS stack..."
  echo "  Image: powerdns/${POWERDNS_IMAGE_NAME}:${POWERDNS_IMAGE_TAG}"
  echo "  Schema: ${schema_url}"

  log "Resetting Docker Compose environment..."
  docker compose -f "$POWERDNS_COMPOSE_FILE" down -v --remove-orphans || true

  mkdir -p "$(dirname "$schema_file")"

  log "Downloading schema..."
  curl -fsSL -o "$schema_file" "$schema_url"

  grep -q "CREATE TABLE" "$schema_file" || {
    err "Downloaded schema looks invalid"
    exit 1
  }

  log "Pulling PowerDNS image..."
  docker pull "powerdns/${POWERDNS_IMAGE_NAME}:${POWERDNS_IMAGE_TAG}"

  log "Starting Docker Compose..."
  docker compose -f "$POWERDNS_COMPOSE_FILE" up -d --remove-orphans

  ok "PowerDNS stack started"
}


# -----------------------------------------------------
# Ensure dnsmasq loads configs from /etc/dnsmasq.d
# -----------------------------------------------------
ensure_dnsmasq_main_conf() {
  log "Ensuring dnsmasq loads /etc/dnsmasq.d..."

  if ! grep -Eq '^\s*conf-dir=/etc/dnsmasq\.d' "$DNSMASQ_MAIN_CONF"; then
    log "Adding conf-dir directive to ${DNSMASQ_MAIN_CONF}..."
    sudo sed -i '/^#conf-dir=\/etc\/dnsmasq\.d/s/^#//' "$DNSMASQ_MAIN_CONF" || true

    if ! grep -Eq '^\s*conf-dir=/etc/dnsmasq\.d' "$DNSMASQ_MAIN_CONF"; then
      echo "conf-dir=/etc/dnsmasq.d" | sudo tee -a "$DNSMASQ_MAIN_CONF" >/dev/null
    fi
  fi

  ok "dnsmasq main config ready"
}


# ----------------------------------------------------------------------------
# Configure dnsmasq to forward *.rezakara.demo to local PowerDNS instance
# ----------------------------------------------------------------------------
configure_dnsmasq() {
  log "Configuring dnsmasq..."

  local changed=0
  sudo mkdir -p /etc/dnsmasq.d

  if ! sudo test -f "$DNSMASQ_CONF" || ! diff -q <(printf "%s\n" "$DNSMASQ_EXPECTED_CONF") <(sudo cat "$DNSMASQ_CONF") >/dev/null; then
    printf "%s\n" "$DNSMASQ_EXPECTED_CONF" | sudo tee "$DNSMASQ_CONF" >/dev/null
    changed=1
  fi

  if (( changed )); then
    restart_dnsmasq
  else
    ok "dnsmasq config already up to date"
    if ! sudo systemctl is-active --quiet dnsmasq; then
      restart_dnsmasq
    fi
  fi

  sudo systemctl is-active --quiet dnsmasq || {
    err "dnsmasq is not running"
    exit 1
  }

  if ! dig @127.0.0.1 google.com +short | grep -q .; then
    err "dnsmasq is running but cannot resolve public domains"
    exit 1
  fi

  ok "dnsmasq is active and resolving"
}


# ----------------------------------------------------------------------------
# Configure NetworkManager to use dnsmasq on 127.0.0.1
# ----------------------------------------------------------------------------
configure_networkmanager_dns() {
  log "Configuring NetworkManager DNS -> dnsmasq..."

  local connection
  local current_dns
  local current_ignore_auto
  local restart_needed=0

  connection="$(get_active_connection)"
  [[ -n "$connection" ]] || { err "Could not detect active NetworkManager connection"; exit 1; }

  echo "🌐 Connection: $connection"

  current_dns="$(sudo nmcli -g ipv4.dns connection show "$connection" | tr -d ' ')"
  current_ignore_auto="$(sudo nmcli -g ipv4.ignore-auto-dns connection show "$connection" | tr -d ' ')"

  if [[ "$current_dns" != "127.0.0.1" ]]; then
    sudo nmcli connection modify "$connection" ipv4.dns "127.0.0.1"
    sudo nmcli connection modify "$connection" ipv6.dns ""
    restart_needed=1
  fi

  if [[ "$current_ignore_auto" != "yes" ]]; then
    sudo nmcli connection modify "$connection" ipv4.ignore-auto-dns yes
    sudo nmcli connection modify "$connection" ipv6.ignore-auto-dns yes
    restart_needed=1
  fi

  if (( restart_needed )); then
    log "Restarting NetworkManager connection..."
    sudo nmcli connection down "$connection" || true
    sudo nmcli connection up "$connection"
  else
    ok "NetworkManager DNS already configured"
  fi

  ensure_systemd_resolved_running
  flush_dns_cache

  log "Verifying DNS chain..."

  # dnsmasq should resolve public names
  if ! dig @127.0.0.1 google.com +short | grep -q .; then
    err "dnsmasq is not resolving internet domains"
    exit 1
  fi

  # PowerDNS may legitimately have no records yet; warn only
  if dig @127.0.0.1 -p 5300 argocd.mgmt.rezakara.demo +short | grep -q .; then
    ok "PowerDNS resolves internal domains directly"
  else
    warn "PowerDNS is reachable on :5300 but has no records yet"
  fi

  # System resolver should still resolve public names
  if ! dig google.com +short | grep -q .; then
    err "System DNS is not resolving internet domains"
    exit 1
  fi

  # Internal resolution through system DNS may not work until records exist
  if dig argocd.mgmt.rezakara.demo +short | grep -q .; then
    ok "System DNS resolves internal domain via dnsmasq -> PowerDNS"
  else
    warn "System DNS path is configured, but no internal record is resolving yet"
  fi

  ok "DNS configured: system -> systemd-resolved -> dnsmasq -> PowerDNS"
}


# ----------------------------------------------------------------------------
# Restore default DNS settings by removing dnsmasq config and resetting NetworkManager
# ----------------------------------------------------------------------------
reset_dns() {
  log "Restoring default DNS through NetworkManager/systemd-resolved..."

  local connection
  local current_dns
  local current_ignore_auto
  local restart_needed=0

  connection="$(get_active_connection)"
  [[ -n "$connection" ]] || { err "Could not detect active NetworkManager connection"; exit 1; }

  echo "🌐 Connection: $connection"

  current_dns="$(sudo nmcli -g ipv4.dns connection show "$connection" | tr -d ' ')"
  current_ignore_auto="$(sudo nmcli -g ipv4.ignore-auto-dns connection show "$connection" | tr -d ' ')"

  if [[ -n "$current_dns" ]]; then
    sudo nmcli connection modify "$connection" ipv4.dns ""
    sudo nmcli connection modify "$connection" ipv6.dns ""
    restart_needed=1
  fi

  if [[ "$current_ignore_auto" != "no" ]]; then
    sudo nmcli connection modify "$connection" ipv4.ignore-auto-dns no
    sudo nmcli connection modify "$connection" ipv6.ignore-auto-dns no
    restart_needed=1
  fi

  if (( restart_needed )); then
    log "Restarting NetworkManager connection..."
    sudo nmcli connection down "$connection" || true
    sudo nmcli connection up "$connection"
  else
    ok "NetworkManager DNS already at default"
  fi

  ensure_systemd_resolved_running
  flush_dns_cache

  if ! dig google.com +short | grep -q .; then
    err "Default system DNS is not resolving public domains after reset"
    exit 1
  fi

  ok "DNS restored to default (dnsmasq bypassed)"
}


# ----------------------------------------------------------------------------
# Remove dnsmasq custom config and stop service
# ----------------------------------------------------------------------------
reset_dnsmasq() {
  log "Removing dnsmasq custom config..."

  # Remove stale direct include if present
  if grep -Eq '^\s*conf-file=/etc/dnsmasq\.d/rezakara\.conf' "$DNSMASQ_MAIN_CONF"; then
    log "Removing direct conf-file reference to ${DNSMASQ_CONF}..."
    sudo sed -i '\|^\s*conf-file=/etc/dnsmasq\.d/rezakara\.conf$|d' "$DNSMASQ_MAIN_CONF"
  fi

  if sudo test -f "$DNSMASQ_CONF"; then
    sudo rm -f "$DNSMASQ_CONF"

    if sudo systemctl is-active --quiet dnsmasq; then
      restart_dnsmasq
    fi
  else
    ok "dnsmasq custom config already absent"
  fi

  ok "dnsmasq reset complete"
}


# -------------------------------
# Stop and remove PowerDNS containers
# -------------------------------
stop_powerdns_containers() {
  local found=0

  for container in pdns pdns-admin pdns-db; do
    if docker container inspect "$container" >/dev/null 2>&1; then
      docker rm -f "$container" >/dev/null
      echo "🧹 Removed $container"
      found=1
    else
      echo "✅ No $container container found"
    fi
  done

  (( found == 1 )) || ok "No PowerDNS containers were running"
}


# ----------------------------------------------------------------------------
# Clean up /etc/hosts entries and flush DNS cache after bootstrapping is complete
# ----------------------------------------------------------------------------
clean_etc_hosts() {
  log "Cleaning /etc/hosts entries..."

  if grep -q 'rezakara\.demo' /etc/hosts; then
    log "Removing rezakara.demo entries..."

    [[ -f /etc/hosts.bak ]] || sudo cp /etc/hosts /etc/hosts.bak
    sudo sed -i '/rezakara\.demo/d' /etc/hosts

    ok "/etc/hosts cleaned"
  else
    ok "No rezakara.demo entries found in /etc/hosts"
  fi

  flush_dns_cache
}


start() {
  ensure_systemd_resolved_running
  vault_login
  load_powerdns_secrets
  start_compose
  ensure_dnsmasq_main_conf
  configure_dnsmasq
  configure_networkmanager_dns
}


reset() {
  ensure_systemd_resolved_running
  reset_dnsmasq
  reset_dns
  stop_powerdns_containers
  flush_dns_cache
}


case "${1:-start}" in
  start)
    start
    ;;
  reset)
    reset
    ;;
  clean_etc_hosts)
    clean_etc_hosts
    ;;
  *)
    echo "Usage: $0 [start|reset|clean_etc_hosts]"
    exit 1
    ;;
esac
