#!/usr/bin/env bash
set -euo pipefail

#-----------------------------------------------------------------------------
# setup-clusters.sh
# Create and configure the local kind clusters for kubepave.
# It creates the management and development clusters,
# enables 'promiscuous' mode on the node containers, and patches CoreDNS
# to forward the rezakara.demo domain to the PowerDNS service.
#-----------------------------------------------------------------------------

# Set the script directory to the current file's directory
DIR="$(cd "$(dirname "$0")" && pwd)"

# Import common functions and variables
source "$DIR/libs/common.sh"
source "$DIR/libs/utils.sh"

# Directory containing the kind cluster configuration files
KIND_CONFIGS_DIR="$DIR/kind-configs"

# Kubernetes version for kind clusters
K8S_VERSION="v1.32.5"

# cluster name → config file
declare -A CLUSTERS=(
  [management]="$KIND_CONFIGS_DIR/management.yaml"
  [development]="$KIND_CONFIGS_DIR/development.yaml"
)

# Preferred start order (management must be first so the LB pool and
# CoreDNS stub for development are derived after the kind network exists)
CLUSTER_ORDER=(management development)


# -----------------------------------------------------------------------------
# Enable 'promiscuous' mode on the kind network interface for each node container.
# Required for Cilium L2 mode, without it ARP announcements are dropped by
# the Docker bridge and LoadBalancer IPs are unreachable.
# In 'promiscuous' mode, a network interface accepts all Ethernet frames it sees,
# not only frames addressed to its own MAC
# In this setup, the kind node containers are connected to a Docker bridge network
# and need to see ARP announcements for LoadBalancer IPs that are not their own.
# -----------------------------------------------------------------------------
enable_promiscuous_mode() {
  # Function arguments:
  #   $1: cluster name (management or development)
  local cluster=$1

  log "Enabling promiscuous mode on $cluster nodes..."

  # Iterate over each node in the kind cluster and set its eth0 interface to promiscuous mode
  kind get nodes --name "$cluster" | while read -r node; do
    docker exec "$node" ip link set eth0 promisc on
    ok "  $node → promisc on"
  done
}


# -----------------------------------------------------------------------------
# Patch CoreDNS in a cluster to forward 'rezakara.demo' to the kind gateway
# where PowerDNS is listening on port 5300.
# Called once per cluster right after creation.
# -----------------------------------------------------------------------------
patch_coredns() {
  # Function arguments:
  #   $1: cluster name (management or development)
  # Local variables:
  #   context: kube context derived from cluster name
  #   pdns_ip: PowerDNS endpoint used as DNS forward target
  #   corefile: current CoreDNS Corefile content, then patched content
  local cluster=$1
  local context
  local pdns_ip
  local corefile

  # Set the kube context
  context="$(kind_context "$cluster")"

  # Get the PowerDNS IP address from the kind network
  pdns_ip="$(get_powerdns_ip)"

  log "Patching CoreDNS in $cluster (→ $pdns_ip:53)..."

  # Get the current CoreDNS Corefile content from the coredns ConfigMap in the kube-system namespace
  corefile=$(kubectl --context "$context" -n "$COREDNS_NS" \
    get cm coredns -o jsonpath='{.data.Corefile}')

  # Remove any existing 'rezakara' DNS block so this will remain idempotent
  corefile=$(sed '/# BEGIN rezakara DNS/,/# END rezakara DNS/d' <<< "$corefile")

  # Append a new 'rezakara' DNS block to the Corefile that forwards queries
  # for the 'rezakara.demo' domain to the PowerDNS service
  corefile="${corefile}
# BEGIN rezakara DNS
${DNS_DOMAIN}:53 {
    forward . ${pdns_ip}:53
    cache 30
    errors
}
# END rezakara DNS
"

  # Patch the coredns ConfigMap with the updated Corefile content
  kubectl --context "$context" -n "$COREDNS_NS" patch cm coredns \
    --type merge \
    -p "{\"data\":{\"Corefile\":$(jq -Rs . <<< "$corefile")}}"

  # Restart the CoreDNS deployment to apply the new configuration
  kubectl --context "$context" -n "$COREDNS_NS" \
    rollout restart deployment coredns >/dev/null

  ok "CoreDNS patched in $cluster"
}


# -----------------------------------------------------------------------------
# Create a single kind cluster
# -----------------------------------------------------------------------------
create_cluster() {
  # Function arguments:
  #   $1: cluster name (management or development)
  # Local variables:
  #   config: path to the kind cluster configuration file for the given cluster name
  local name=$1
  local config=${CLUSTERS[$name]}

  # Skip creation if the cluster already exists
  if kind get clusters 2>/dev/null | grep -qx "$name"; then
    warn "$name already exists — skipping"
    return
  fi

  log "Creating $name (k8s $K8S_VERSION)..."

  # No --wait: with the default CNI disabled, nodes stay NotReady until Cilium
  # is installed (done immediately after, in start()). Waiting here would time out.
  kind create cluster \
    --name "$name" \
    --config "$config" \
    --image "kindest/node:${K8S_VERSION}"

  ok "$name created"
}


# -----------------------------------------------------------------------------
# Delete a single kind cluster
# -----------------------------------------------------------------------------
delete_cluster() {
  # Function arguments:
  #   $1: cluster name (management or development)
  local name=$1

  # Delete the cluster if it exists; otherwise, log a warning
  if kind get clusters 2>/dev/null | grep -qx "$name"; then
    log "Deleting $name..."
    kind delete cluster --name "$name"
    ok "$name deleted"
  else
    warn "$name not found — skipping"
  fi
}


# -----------------------------------------------------------------------------
# Clean up stale 'kubeconfig' contexts left behind after deletion
# -----------------------------------------------------------------------------
clean_kubeconfig() {
  log "Cleaning kubeconfig..."

  # Iterate over all cluster names and remove their contexts, clusters, and users
  # from the 'kubeconfig' if they exist
  for name in "${!CLUSTERS[@]}"; do
    local ctx="kind-${name}"
    if kubectl config get-contexts "$ctx" >/dev/null 2>&1; then
      kubectl config delete-context "$ctx" >/dev/null
      kubectl config delete-cluster "$ctx" >/dev/null 2>/dev/null || true
      kubectl config delete-user "$ctx" >/dev/null 2>/dev/null || true
    fi
  done

  ok "kubeconfig clean"
}


# -----------------------------------------------------------------------------
# Print a summary of running clusters and their LB pools
# -----------------------------------------------------------------------------
status() {
  echo ""
  echo "Kind clusters:"
  # List all kind clusters and their corresponding kube contexts
  kind get clusters 2>/dev/null | grep -E "^(management|development)$" | while read -r c; do
    echo "  $c"
    echo "    context: kind-$c"
  done || echo "  (none)"

  echo ""

  # Print the kind Docker network CIDR, PowerDNS IP, and LoadBalancer pool ranges
  # for management and development clusters
  if docker network inspect kind >/dev/null 2>&1; then
    echo "kind network CIDR    : $(get_kind_cidr)"
    echo "PowerDNS IP          : $(get_powerdns_ip)"
    echo "LB pool management   : $(get_lb_pool management)"
    echo "LB pool development     : $(get_lb_pool development)"
  else
    echo "kind Docker network  : not found"
  fi

  echo ""
}


# -----------------------------------------------------------------------------
# Start the kind clusters in the preferred order, enable promiscuous mode,
# and patch CoreDNS in each cluster to forward 'rezakara.demo' to PowerDNS
# -----------------------------------------------------------------------------
start() {
  log "Starting kind clusters..."

  # Pre-create the kind Docker network with a pinned subnet so the LB pool
  # ranges are stable across cluster rebuilds. Docker allocates from
  # 192.168.211.0/24 in /27 chunks; pinning here prevents a different /27
  # from being assigned after 'kind:down'. kind reuses an existing network.
  if ! docker network inspect kind >/dev/null 2>&1; then
    docker network create kind \
      --subnet 192.168.211.64/27 \
      --gateway 192.168.211.65 >/dev/null
    log "Created pinned kind Docker network (192.168.211.64/27)"
  fi

  for name in "${CLUSTER_ORDER[@]}"; do
    create_cluster "$name"
    echo "--------------------------------"
  done

  # Always ensure promiscuous mode is on — required for Cilium L2 ARP.
  # Always repatch CoreDNS — ensures the PowerDNS IP is current after any redeploy.
  # Both operations are idempotent. CoreDNS stays Pending until Cilium (the CNI)
  # is installed by the next bootstrap step (setup-cilium.sh); the patch persists.
  for name in "${CLUSTER_ORDER[@]}"; do
    enable_promiscuous_mode "$name"
    patch_coredns "$name"
  done

  kubectl config use-context "kind-management"

  status
}


# -----------------------------------------------------------------------------
# Destroy all kind clusters and clean up kubeconfig contexts
# -----------------------------------------------------------------------------
destroy() {
  log "Destroying kind clusters..."

  for name in "${CLUSTER_ORDER[@]}"; do
    delete_cluster "$name"
  done

  clean_kubeconfig

  ok "All clusters removed"
}


# -----------------------------------------------------------------------------
# Main script entry point: parse command-line arguments
# and execute the appropriate function
# -----------------------------------------------------------------------------
case "${1:-start}" in
  start)   start ;;
  destroy) destroy ;;
  status)  status ;;
  *)
    echo "Usage: $0 [start|destroy|status]"
    exit 1
    ;;
esac
