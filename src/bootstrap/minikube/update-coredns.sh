#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=libs/common.sh
source "$DIR/libs/common.sh"
# shellcheck source=libs/utils.sh
source "$DIR/libs/utils.sh"


# CoreDNS configuration for workload clusters to resolve vault and oidc endpoints in management cluster
DNS_DOMAIN="mgmt.rezakara.demo"
DNS_HOST="vault.mgmt.rezakara.demo"


# -----------------------------------------------------------------------------
# Wait for Traefik LoadBalancer IP in management cluster
# -----------------------------------------------------------------------------
wait_for_traefik_ip() {
  local ip=""

  echo "🌐 Waiting for Traefik IP in $MANAGEMENT_PROFILE..." >&2

  for _ in {1..60}; do
    ip=$(kubectl --context "$MANAGEMENT_PROFILE" -n "$TRAEFIK_NS" \
      get svc "$TRAEFIK_SVC" \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)

    if [[ -n "$ip" ]]; then
      echo "$ip"
      return 0
    fi

    sleep 2
  done

  echo "❌ Traefik IP not found in $MANAGEMENT_PROFILE" >&2
  exit 1
}


# -----------------------------------------------------------------------------
# Update CoreDNS in workload clusters
# -----------------------------------------------------------------------------
update_dns() {
  local profile=$1
  local ip=$2
  local corefile

  echo "✏️  Updating CoreDNS in $profile ($DNS_HOST → $ip)"

  corefile=$(kubectl --context "$profile" -n "$COREDNS_NS" \
    get cm coredns -o jsonpath='{.data.Corefile}')

  # Remove previous block if it exists
  corefile=$(sed '/^mgmt.rezakara.demo:53 {/,/^}/d' <<< "$corefile")

  # Append new DNS mapping block
  corefile="$corefile

$DNS_DOMAIN:53 {
    hosts {
        $ip vault.$DNS_DOMAIN
        $ip oidc.$DNS_DOMAIN
        fallthrough
    }
    cache 30
}
"

  kubectl --context "$profile" -n "$COREDNS_NS" patch cm coredns \
    --type merge \
    -p "{\"data\":{\"Corefile\":$(jq -Rs . <<< "$corefile")}}"

  kubectl --context "$profile" -n "$COREDNS_NS" \
    rollout restart deployment coredns >/dev/null

  echo "✅ DNS updated"
}


# -----------------------------------------------------------------------------
# Main workflow
# -----------------------------------------------------------------------------
main() {
  local ip

  ip=$(wait_for_traefik_ip)

  get_minikube_profiles | while read -r profile; do
    echo "🔎 Cluster: $profile"
    update_dns "$profile" "$ip"
    echo "--------------------------------"
  done

  echo "🏁 Done"
}

main "$@"
