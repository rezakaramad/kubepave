#!/usr/bin/env bash
set -euo pipefail

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
bind-interfaces
server=/rezakara.demo/127.0.0.1#5300
server=8.8.8.8
server=1.1.1.1
EOF
)

# -----------------------------------------------------
# Load secrets from Vault and export as environment variables
# -----------------------------------------------------
load_powerdns_secrets() {
  echo "📥 Loading secrets from Vault..."

  POSTGRES_DB="pdns"
  POSTGRES_USER="$(vault kv get -field=user $VAULT_DB_PATH)"
  POSTGRES_PASSWORD="$(vault kv get -field=password $VAULT_DB_PATH)"
  PDNS_API_KEY="$(vault kv get -field=key $VAULT_API_PATH)"

  [ -n "$POSTGRES_USER" ] || { echo "❌ DB user missing"; exit 1; }
  [ -n "$POSTGRES_PASSWORD" ] || { echo "❌ DB password missing"; exit 1; }
  [ -n "$PDNS_API_KEY" ] || { echo "❌ API key missing"; exit 1; }

  export POSTGRES_DB
  export POSTGRES_USER
  export POSTGRES_PASSWORD
  export PDNS_API_KEY

  echo "✅ Secrets loaded and exported"
}


# -----------------------------------------------------
# Start PowerDNS stack using Docker Compose
# -----------------------------------------------------
start_compose() {
  local SCHEMA_FILE="${DIR}/../powerdns/schema.pgsql.sql"
  local SCHEMA_URL="https://raw.githubusercontent.com/PowerDNS/pdns/rel/${POWERDNS_IMAGE_BRANCH}/modules/gpgsqlbackend/schema.pgsql.sql"

  export POWERDNS_IMAGE_NAME
  export POWERDNS_IMAGE_TAG

  echo "🚀 Starting PowerDNS stack..."
  echo "🔧 Using:"
  echo "  Image: powerdns/${POWERDNS_IMAGE_NAME}:${POWERDNS_IMAGE_TAG}"
  echo "  Schema: $SCHEMA_URL"

  echo "🧹 Resetting environment (full clean)..."
  docker compose -f "$POWERDNS_COMPOSE_FILE" down -v --remove-orphans || true

  mkdir -p "$(dirname "$SCHEMA_FILE")"

  echo "📥 Downloading schema..."
  curl -fsSL -o "$SCHEMA_FILE" "$SCHEMA_URL" || {
    echo "❌ Failed to download schema"
    exit 1
  }

  if ! grep -q "CREATE TABLE" "$SCHEMA_FILE"; then
    echo "❌ Downloaded schema looks invalid"
    exit 1
  fi

  echo "🐳 Pulling PowerDNS image..."
  docker pull "powerdns/${POWERDNS_IMAGE_NAME}:${POWERDNS_IMAGE_TAG}"

  echo "🚀 Starting Docker Compose..."
  docker compose -f "$POWERDNS_COMPOSE_FILE" up -d --remove-orphans || {
    echo "❌ Docker Compose failed"
    exit 1
  }

  echo "🎉 Stack started"
}


# -----------------------------------------------------
# Ensure dnsmasq loads configs from /etc/dnsmasq.d (required for our custom config)
# -----------------------------------------------------
ensure_dnsmasq_main_conf() {
  echo "🔧 Ensuring dnsmasq loads /etc/dnsmasq.d..."

  if ! grep -Eq '^\s*conf-dir=/etc/dnsmasq\.d' "$DNSMASQ_MAIN_CONF"; then
    echo "Adding conf-dir directive..."

    sudo sed -i '/^#conf-dir=\/etc\/dnsmasq\.d/s/^#//' "$DNSMASQ_MAIN_CONF" || \
    echo "conf-dir=/etc/dnsmasq.d" | sudo tee -a "$DNSMASQ_MAIN_CONF" >/dev/null
  fi
}


# ----------------------------------------------------------------------------
# Configure dnsmasq to forward *.rezakara.demo to local PowerDNS instance
# ----------------------------------------------------------------------------
configure_dnsmasq() {
  echo "🔧 Configuring dnsmasq..."

  local changed=0
  sudo mkdir -p /etc/dnsmasq.d

  if ! sudo test -f "$DNSMASQ_CONF" || ! diff -q <(printf "%s\n" "$DNSMASQ_EXPECTED_CONF") <(sudo cat "$DNSMASQ_CONF") >/dev/null; then
    printf "%s\n" "$DNSMASQ_EXPECTED_CONF" | sudo tee "$DNSMASQ_CONF" >/dev/null
    changed=1
  fi

  if (( changed )); then
    echo "🔄 Restarting dnsmasq..."
    sudo systemctl restart dnsmasq || sudo systemctl start dnsmasq
  else
    echo "✅ dnsmasq already up to date"
  fi

  if ! sudo systemctl is-active --quiet dnsmasq; then
    echo "❌ dnsmasq is not running"
    exit 1
  fi
}


# ----------------------------------------------------------------------------
# Configure systemd-resolved to forward DNS queries for *.rezakara.demo to local PowerDNS instance
# ----------------------------------------------------------------------------
configure_networkmanager_dns() {
  echo "🔧 Configuring DNS via NetworkManager → dnsmasq..."

  local connection
  local current_dns
  local current_ignore_auto
  local restart_needed=0

  # Get active connection (WiFi / Ethernet)
  connection="$(get_active_connection)"
  if [[ -z "$connection" ]]; then
    echo "❌ Could not detect active NetworkManager connection"
    exit 1
  fi

  echo "🌐 Connection: $connection"

  # Check if DNS already includes 127.0.0.1
  if ! nmcli -g ipv4.dns connection show "$connection" | grep -wq "127.0.0.1"; then
    nmcli connection modify "$connection" ipv4.dns "127.0.0.1"
    restart_needed=1
  fi

  # Check ignore-auto-dns
  current_ignore_auto="$(nmcli -g ipv4.ignore-auto-dns connection show "$connection" | tr -d ' ')"

  if [[ "$current_ignore_auto" != "yes" ]]; then
    nmcli connection modify "$connection" ipv4.ignore-auto-dns yes
    nmcli connection modify "$connection" ipv6.ignore-auto-dns yes
    restart_needed=1
  fi

  if (( restart_needed )); then
    echo "🔄 Restarting connection..."
    nmcli connection down "$connection"
    nmcli connection up "$connection"
  else
    echo "✅ NetworkManager DNS already configured"
  fi

  echo "🧹 Flushing DNS cache..."
  sudo resolvectl flush-caches

  echo "🔍 Verifying..."

  # Internet via dnsmasq
  if ! dig @127.0.0.1 google.com +short | grep -q .; then
    echo "❌ dnsmasq not resolving internet domains"
    exit 1
  fi

  # PowerDNS (authoritative for internal domains)
  if ! dig @127.0.0.1 argocd.mgmt.rezakara.demo +short | grep -q .; then
    echo "❌ dnsmasq not resolving internal domains"
    exit 1
  fi

  # Internal domains via dnsmasq → PowerDNS
  if ! dig @127.0.0.1 -p 5300 argocd.mgmt.rezakara.demo +short | grep -q .; then
    echo "⚠️ PowerDNS has no records yet (expected before ArgoCD sync)"
  else
    echo "✅ PowerDNS resolving internal domains"
  fi

  # System DNS resolving internet domains
  if ! dig google.com +short | grep -q .; then
    echo "❌ system DNS not resolving internet domains"
    exit 1
  fi

  # System DNS resolving internal domains (via dnsmasq → PowerDNS)
  if ! dig argocd.mgmt.rezakara.demo +short | grep -q .; then
    echo "❌ system DNS not using dnsmasq"
    exit 1
  fi

  echo "✅ DNS fully configured (system → dnsmasq → PowerDNS)"
}


reset_dns() {
  echo "♻️  Restoring default DNS (NetworkManager)..."

  local connection current_dns current_ignore_auto restart_needed=0

  connection="$(get_active_connection)"
  if [[ -z "$connection" ]]; then
    echo "❌ Could not detect active connection"
    exit 1
  fi

  echo "🌐 Connection: $connection"

  current_dns="$(nmcli -g ipv4.dns connection show "$connection" | tr -d ' ')"
  current_ignore_auto="$(nmcli -g ipv4.ignore-auto-dns connection show "$connection" | tr -d ' ')"

  if [[ -n "$current_dns" ]]; then
    nmcli connection modify "$connection" ipv4.dns ""
    nmcli connection modify "$connection" ipv6.dns ""
    restart_needed=1
  fi

  if [[ "$current_ignore_auto" != "no" ]]; then
    nmcli connection modify "$connection" ipv4.ignore-auto-dns no
    nmcli connection modify "$connection" ipv6.ignore-auto-dns no
    restart_needed=1
  fi

  if (( restart_needed )); then
    echo "🔄 Restarting connection..."
    nmcli connection down "$connection"
    nmcli connection up "$connection"
  else
    echo "✅ NetworkManager DNS already at default"
  fi

  sudo resolvectl flush-caches
  echo "✅ DNS restored to default"
}

reset_dnsmasq() {
  echo "🧹 Removing dnsmasq custom config..."

  if sudo test -f "$DNSMASQ_CONF"; then
    sudo rm -f "$DNSMASQ_CONF"
    sudo systemctl restart dnsmasq
  else
    echo "✅ dnsmasq custom config already absent"
  fi

  echo "✅ dnsmasq reset"
}


# -------------------------------
# Stop and remove PowerDNS containers
# -------------------------------
stop_powerdns_containers() {
  for container in pdns pdns-admin pdns-db; do
    if docker container inspect "$container" >/dev/null 2>&1; then
      docker rm -f "$container" >/dev/null
      echo "🧹 Removed $container"
    else
      echo "✅ No $container container found"
    fi
  done
}


# -------------------------------
# Flush DNS cache
# -------------------------------
flush_dns_cache() {
  echo "🔄 Flushing DNS cache..."

  if command -v resolvectl >/dev/null 2>&1; then
    sudo resolvectl flush-caches
    echo "✅ DNS cache flushed (systemd-resolved)"
  elif command -v systemd-resolve >/dev/null 2>&1; then
    sudo systemd-resolve --flush-caches
    echo "✅ DNS cache flushed (systemd-resolve)"
  else
    echo "⚠️ No supported DNS cache tool found"
  fi
}


# ----------------------------------------------------------------------------
# Clean up /etc/hosts entries and flush DNS cache after bootstrapping is complete
# ----------------------------------------------------------------------------
clean_etc_hosts() {
  echo "🧼 Cleaning /etc/hosts entries..."

  if grep -q 'rezakara.demo' /etc/hosts; then
    echo "🧹 Removing rezakara.demo entries"

    # Backup /etc/hosts if not already backed up
    [[ -f /etc/hosts.bak ]] || sudo cp /etc/hosts /etc/hosts.bak

    sudo sed -i '/rezakara\.demo/d' /etc/hosts

    echo "✅ /etc/hosts cleaned. We use PowerDNS going forward, so no need for local entries."
  else
    echo "✅ No rezakara.demo entries found"
  fi

  echo "🔄 Flushing DNS cache..."
  flush_dns_cache
}


start() {
  vault_login
  load_powerdns_secrets
  start_compose
  ensure_dnsmasq_main_conf
  configure_dnsmasq
  configure_networkmanager_dns
}

reset() {
  reset_dns
  reset_dnsmasq
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
