#!/usr/bin/env bash
set -euo pipefail

#-----------------------------------------------------------------------------
# setup-dns.sh
# Deploy PowerDNS in the management cluster and configure systemd-resolved
# on the host to route '*.rezakara.demo' to PowerDNS.
#-----------------------------------------------------------------------------

# Set the script directory to the current file's directory
DIR="$(cd "$(dirname "$0")" && pwd)"

# Import common functions and variables
source "$DIR/libs/common.sh"
source "$DIR/libs/utils.sh"

# PowerDNS namespace and Helm chart location
POWERDNS_NAMESPACE="powerdns"
POWERDNS_CHART="$REPO_ROOT/charts/powerdns"

# Shared platform credentials file: generated values are never committed
SECRETS_FILE="$REPO_ROOT/.platform.env"

# systemd-resolved drop-in: routes '*.rezakara.demo' to PowerDNS from the host
RESOLVED_DROPIN_DIR="/etc/systemd/resolved.conf.d"
RESOLVED_DROPIN="$RESOLVED_DROPIN_DIR/rezakara.demo.conf"


# -----------------------------------------------------------------------------
# Add PowerDNS credentials to '.platform.env' on first run.
# -----------------------------------------------------------------------------
init_secrets() {
  # Skip generation if both PowerDNS credentials already exist in the shared file.
  if grep -q '^export POWERDNS_DB_PASSWORD=' "$SECRETS_FILE" 2>/dev/null \
    && grep -q '^export POWERDNS_API_KEY=' "$SECRETS_FILE" 2>/dev/null; then
    return
  fi

  log "Adding PowerDNS credentials to $SECRETS_FILE"

  # Migrate credentials from the legacy file if it exists; otherwise generate them.
  local db_password api_key
  if [[ -f "$REPO_ROOT/.powerdns.env" ]]; then
    # shellcheck source=/dev/null
    source "$REPO_ROOT/.powerdns.env"
  else
    db_password="$(openssl rand -base64 24 | tr -d '=')"
    api_key="$(openssl rand -base64 24 | tr -d '=')"
  fi

  touch "$SECRETS_FILE"
  printf 'export POWERDNS_DB_PASSWORD="%s"\n' "$db_password" >> "$SECRETS_FILE"
  printf 'export POWERDNS_API_KEY="%s"\n' "$api_key" >> "$SECRETS_FILE"

  # Set file permissions to be readable only by the owner
  chmod 600 "$SECRETS_FILE"

  ok "Secrets written to $SECRETS_FILE"
}

# -----------------------------------------------------------------------------
# Load PowerDNS secrets from '.platform.env' into the environment.
# -----------------------------------------------------------------------------
load_secrets() {
  # Skip loading if the secrets file does not exist, and print an error message
  if [[ ! -f "$SECRETS_FILE" ]]; then
    err "Secrets file not found: $SECRETS_FILE — run '$0 start' first"
    exit 1
  fi

  # Load the secrets file into the environment
  log "Loading PowerDNS secrets from $SECRETS_FILE"
  source "$SECRETS_FILE"
}


# -----------------------------------------------------------------------------
# Create namespace and Kubernetes secrets in the management cluster
# -----------------------------------------------------------------------------
apply_k8s_secrets() {
  # Local variables:
  #   context: kube context derived from cluster name
  local context
  context="$(kind_context management)"

  log "Creating namespace $POWERDNS_NAMESPACE..."

  # Create the PowerDNS namespace in the management cluster if it does not already exist
  kubectl --context "$context" \
    create namespace "$POWERDNS_NAMESPACE" \
    --dry-run=client -o yaml | kubectl --context "$context" apply -f -

  log "Writing PowerDNS secrets to cluster..."

  # Create Kubernetes secrets for the PowerDNS database password the management cluster
  kubectl --context "$context" \
    -n "$POWERDNS_NAMESPACE" \
    create secret generic powerdns-db-credentials \
    --from-literal=password="$POWERDNS_DB_PASSWORD" \
    --dry-run=client -o yaml | kubectl --context "$context" apply -f -

  # Create Kubernetes secrets for the PowerDNS API key in the management cluster
  kubectl --context "$context" \
    -n "$POWERDNS_NAMESPACE" \
    create secret generic powerdns-api-key \
    --from-literal=key="$POWERDNS_API_KEY" \
    --dry-run=client -o yaml | kubectl --context "$context" apply -f -

  ok "Secrets applied"
}


# -----------------------------------------------------------------------------
# Deploy PowerDNS via Helm into the management cluster
# -----------------------------------------------------------------------------
deploy_powerdns() {
  # Local variables:
  #   context: kube context derived from cluster name
  #   pdns_ip: IP address of the PowerDNS service in the management cluster
  local context pdns_ip
  context="$(kind_context management)"
  pdns_ip="$(get_powerdns_ip)"

  log "Deploying PowerDNS to management cluster (node IP: $pdns_ip)..."

  # We had to create the namespace and secrets imperatively above because Helm cannot
  # create them before the chart is installed. 
  # Adopt the namespace into Helm management in case it was created imperatively
  # by a prior failed run. Helm requires these to recognise the namespace as its own.
  kubectl --context "$context" annotate namespace "$POWERDNS_NAMESPACE" \
    meta.helm.sh/release-name=powerdns \
    meta.helm.sh/release-namespace="$POWERDNS_NAMESPACE" \
    --overwrite
  kubectl --context "$context" label namespace "$POWERDNS_NAMESPACE" \
    app.kubernetes.io/managed-by=Helm \
    --overwrite

  # Deploy PowerDNS Helm chart into the management cluster, waiting for all resources to be ready
  helm upgrade --install powerdns "$POWERDNS_CHART" \
    --kube-context "$context" \
    --namespace "$POWERDNS_NAMESPACE" \
    --timeout 5m \
    --wait

  ok "PowerDNS deployed"
}


# -----------------------------------------------------------------------------
# Wait for PowerDNS to answer DNS queries on the node IP
# -----------------------------------------------------------------------------
wait_for_powerdns_ip() {
  # Local variables:
  #   pdns_ip: IP address of the PowerDNS service in the management cluster
  local pdns_ip
  pdns_ip="$(get_powerdns_ip)"

  log "Waiting for PowerDNS to answer on $pdns_ip:53..."

  # Wait for PowerDNS to respond to DNS queries on the node IP, retrying for up to 2 minutes
  for _ in {1..60}; do
    if dig @"$pdns_ip" rezakara.demo SOA +time=2 +tries=1 >/dev/null 2>&1; then
      ok "PowerDNS reachable at $pdns_ip:53"
      return 0
    fi
    sleep 2
  done

  err "Timed out waiting for PowerDNS"
  exit 1
}


# -----------------------------------------------------------------------------
# Write systemd-resolved drop-in to route '*.rezakara.demo' to PowerDNS from host.
# This is a one-time operation — the IP is fixed, so this never needs updating.
# -----------------------------------------------------------------------------
configure_resolved() {
  # Local variables:
  #   pdns_ip: IP address of the PowerDNS service in the management cluster
  local pdns_ip
  pdns_ip="$(get_powerdns_ip)"

  local expected
  expected="$(cat <<EOF
[Resolve]
DNS=${pdns_ip}
Domains=~rezakara.demo
EOF
)"

  if sudo test -f "$RESOLVED_DROPIN" && \
     diff -q <(printf "%s\n" "$expected") <(sudo cat "$RESOLVED_DROPIN") >/dev/null 2>&1; then
    ok "systemd-resolved already configured"
    return
  fi

  log "Writing systemd-resolved drop-in → $RESOLVED_DROPIN"
  sudo mkdir -p "$RESOLVED_DROPIN_DIR"
  printf "%s\n" "$expected" | sudo tee "$RESOLVED_DROPIN" >/dev/null
  sudo systemctl restart systemd-resolved

  ok "systemd-resolved configured (*.rezakara.demo → $pdns_ip)"
}


# -----------------------------------------------------------------------------
# Remove systemd-resolved drop-in and restore default DNS
# -----------------------------------------------------------------------------
remove_resolved() {
  if sudo test -f "$RESOLVED_DROPIN"; then
    log "Removing systemd-resolved drop-in..."
    log "sudo required to remove $RESOLVED_DROPIN and restart systemd-resolved"
    sudo rm -f "$RESOLVED_DROPIN"
    sudo systemctl restart systemd-resolved
    ok "systemd-resolved restored"
  else
    ok "systemd-resolved drop-in already absent"
  fi
}


# -----------------------------------------------------------------------------
# Start the PowerDNS deployment and configure systemd-resolved on the host
# -----------------------------------------------------------------------------
start() {
  init_secrets
  load_secrets
  apply_k8s_secrets
  deploy_powerdns
  wait_for_powerdns_ip
  configure_resolved
}

# -----------------------------------------------------------------------------
# Destroy PowerDNS deployment and remove systemd-resolved drop-in
# -----------------------------------------------------------------------------
reset() {
  remove_resolved

  local context
  context="$(kind_context management)"

  if kubectl --context "$context" get namespace "$POWERDNS_NAMESPACE" >/dev/null 2>&1; then
    log "Uninstalling PowerDNS..."
    helm uninstall powerdns \
      --kube-context "$context" \
      --namespace "$POWERDNS_NAMESPACE" || true
    kubectl --context "$context" \
      delete namespace "$POWERDNS_NAMESPACE" --ignore-not-found
    ok "PowerDNS removed"
  else
    ok "PowerDNS already absent"
  fi
}


# -----------------------------------------------------------------------------
# Main script entry point: parse command-line arguments
# and execute the appropriate function
# -----------------------------------------------------------------------------
case "${1:-start}" in
  start) start ;;
  reset) reset ;;
  *)
    echo "Usage: $0 [start|reset]"
    exit 1
    ;;
esac
