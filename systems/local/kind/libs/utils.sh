#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=libs/common.sh
source "$DIR/libs/common.sh"

# Returns all running kind clusters managed by this setup
get_kind_clusters() {
  kind get clusters 2>/dev/null \
    | grep -E "^(management|workload)$" || true
}

# Returns tenant (non-management) clusters
get_kind_tenant_clusters() {
  get_kind_clusters | grep -v "^${MANAGEMENT_CLUSTER}$" || true
}

# Returns the Docker bridge gateway IP for the kind network (IPv4 only).
get_kind_gateway() {
  docker network inspect kind \
    --format '{{range .IPAM.Config}}{{.Gateway}}{{"\n"}}{{end}}' 2>/dev/null \
    | grep -v ':' \
    | head -1
}

# Returns the IPv4 CIDR of the kind Docker network (e.g. "192.168.211.64/27").
get_kind_cidr() {
  docker network inspect kind \
    --format '{{range .IPAM.Config}}{{.Subnet}}{{"\n"}}{{end}}' 2>/dev/null \
    | grep -v ':' \
    | head -1
}

# Returns the metallb IP pool range for a given cluster.
# Pools are carved from the upper end of the kind CIDR to avoid collisions
# with the gateway and node IPs which are allocated from the lower end.
# Usage: get_metallb_pool management
#        get_metallb_pool workload
get_metallb_pool() {
  local cluster=$1
  local cidr
  cidr="$(get_kind_cidr)"

  python3 - "$cidr" "$cluster" "$METALLB_MGMT_POOL_SIZE" "$METALLB_WL_POOL_SIZE" <<'EOF'
import sys, ipaddress
cidr, cluster, mgmt_size, wl_size = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
hosts = list(ipaddress.IPv4Network(cidr, strict=False).hosts())
if cluster == "management":
    pool = hosts[-mgmt_size:]
elif cluster == "workload":
    pool = hosts[-(mgmt_size + wl_size):-mgmt_size]
else:
    sys.exit(f"Unknown cluster: {cluster}")
print(f"{pool[0]}-{pool[-1]}")
EOF
}

# Returns the Docker bridge IP of the management cluster node.
# With hostNetwork=true on the PowerDNS pod, it binds to this IP.
# Reachable from pods in both clusters (via CNI → node → Docker bridge)
# and from the host (via Docker bridge directly).
get_management_node_ip() {
  docker inspect management-control-plane \
    --format '{{.NetworkSettings.Networks.kind.IPAddress}}' 2>/dev/null
}

# Returns the IP where PowerDNS port 53 is reachable by all consumers.
get_powerdns_ip() {
  get_management_node_ip
}

# Returns the kubeconfig context name for a kind cluster
kind_context() {
  local cluster=$1
  echo "kind-${cluster}"
}

# Vault login
vault_login() {
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
