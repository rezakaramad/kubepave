#!/usr/bin/env bash
set -euo pipefail

# Get all Minikube profiles
get_minikube_profiles() {
  minikube profile list -o json \
    | jq -r '
        .valid[]
        | select(.Status == "OK")
        | .Name
        | select(startswith("minikube-"))
      '
}

# Get workload Minikube profiles only
get_minikube_tenant_profiles() {
  minikube profile list -o json \
    | jq -r --arg mgmt "$MANAGEMENT_PROFILE" '
        .valid[]
        | select(.Status == "OK")
        | .Name
        | select(startswith("minikube-") and . != $mgmt)
      '
}

# Vault login
vault_login() {
  local VAULT_NAMESPACE="vault"

  echo "🔐 Authenticating to Vault..."

  kubectl wait \
    --for=condition=Ready pod \
    -l app.kubernetes.io/name=vault \
    -n "$VAULT_NAMESPACE" \
    --timeout=120s

  VAULT_POD=$(kubectl get pods -n "$VAULT_NAMESPACE" \
    -l app.kubernetes.io/name=vault \
    -o jsonpath='{.items[0].metadata.name}')

  VAULT_TOKEN=$(kubectl exec -n "$VAULT_NAMESPACE" "$VAULT_POD" -- \
    sh -c "grep 'Initial Root Token:' /vault/data/init.txt | awk '{print \$4}'")

  export VAULT_ADDR="https://vault.mgmt.rezakara.demo"
  export VAULT_TOKEN="$VAULT_TOKEN"
  export VAULT_SKIP_VERIFY=true

  vault secrets enable -path=local kv-v2 2>/dev/null || true
}

# ----------------------------------------------------------------------------
# Detect user shell for installing kubectl plugins
# ----------------------------------------------------------------------------
detect_shell() {
  local shell

  shell="$(ps -p $$ -o comm=)"

  case "$shell" in
    fish) echo "fish" ;;
    zsh)  echo "zsh" ;;
    bash) echo "bash" ;;
    *)    echo "unknown" ;;
  esac
}

# -----------------------------------------------------
# Get active network connection (for DNS setup) using nmcli
# -----------------------------------------------------
get_active_connection() {
  nmcli -t -f NAME,DEVICE connection show --active \
    | awk -F: '$2 != "" && $1 != "lo" {print $1; exit}'
}

# ----------------------------------------------------------------------------
# Update /etc/hosts with management cluster LoadBalancer IP for accessing Argo CD, Vault
# and Keycloak during bootstrapping before PowerDNS is set up. This is necessary because
# the LoadBalancer IP is dynamic and must be resolved to access the services.
# ----------------------------------------------------------------------------
update_hosts() {
  echo "⚙️  Updating /etc/hosts (requires sudo privileges)"

  # Wait for LoadBalancer IP
  while true; do
    LB_IP=$(kubectl get svc traefik-mgmt \
      -n "$PLATFORM_NAMESPACE" \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)

    [[ -n "$LB_IP" ]] && break
    sleep 2
  done

  sudo cp /etc/hosts /etc/hosts.bak
  sudo sed -i.bak '/rezakara.demo/d' /etc/hosts

  {
    echo "$LB_IP argocd.mgmt.rezakara.demo"
    echo "$LB_IP vault.mgmt.rezakara.demo"
    echo "$LB_IP oidc.mgmt.rezakara.demo"
  } | sudo tee -a /etc/hosts >/dev/null
}
