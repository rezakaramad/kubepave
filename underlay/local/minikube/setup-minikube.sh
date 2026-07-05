#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=libs/common.sh
source "$DIR/libs/common.sh"
# shellcheck source=libs/utils.sh
source "$DIR/libs/utils.sh"

# Kubernetes version to use for Minikube clusters
K8S_VERSION="v1.35.0"

# profile → "cpu memory"
declare -A CLUSTERS=(
  [minikube-management]="4 8192 10.101.0.0/16"
  [minikube-workload]="4 8192 10.102.0.0/16"
)

start_cluster () {
  local profile=$1
  local cpus=$2
  local memory=$3
  local service_cidr=$4

  echo "🚀 Starting $profile ($cpus CPU / ${memory}MB)"
  echo "   📡 Service CIDR: $service_cidr"

  if minikube status -p "$profile" >/dev/null 2>&1; then
    echo "   ℹ️ already running — skipping"
    return
  fi

  minikube start -p "$profile" \
    --driver=kvm2 \
    --network=kubepave \
    --kubernetes-version="$K8S_VERSION" \
    --cpus="$cpus" \
    --memory="$memory" \
    --service-cluster-ip-range="$service_cidr" \
    --cache-images
}


# --------------------------------------------------------------------------------
# Kill any existing tunnels/proxies before starting new clusters
# --------------------------------------------------------------------------------
kill_minikube_tunnels() {
  if pgrep -f "minikube tunnel" >/dev/null; then
    pkill -f "minikube tunnel"
    echo "⏹ Stopped minikube tunnels"
  else
    echo "✅ No minikube tunnels running"
  fi

  if pgrep -f "kubectl.*proxy" >/dev/null; then
    pkill -f "kubectl.*proxy"
    echo "⏹ Stopped kubectl proxies"
  else
    echo "✅ No kubectl proxies running"
  fi
}


# --------------------------------------------------------------------------------
# Delete all Minikube clusters and clean kubeconfig
# --------------------------------------------------------------------------------
delete_minikube_clusters() {
  echo "🧨 Deleting all Minikube clusters..."

  if minikube profile list -o json | jq -e '.valid | length > 0' >/dev/null; then
    minikube delete --all
    echo "🧨 All Minikube clusters deleted"
  else
    echo "✅ No Minikube clusters found"
  fi

  # Clean kubeconfig
  echo "🧼 Cleaning kubeconfig leftovers..."

  mapfile -t contexts < <(kubectl config get-contexts -o name | grep '^minikube-' || true)

  if ((${#contexts[@]} > 0)); then
    for ctx in "${contexts[@]}"; do
      kubectl config delete-context "$ctx"
    done
    echo "✅ Removed Minikube contexts"
  else
    echo "✅ No Minikube contexts found"
  fi
}


# --------------------------------------------------------------------------------
# List active Minikube tunnels
# --------------------------------------------------------------------------------
list_minikube_tunnels() {
  echo "🔌 Active Minikube tunnels:"
  if pgrep -af "minikube tunnel -p minikube-" >/dev/null; then
    pgrep -af "minikube tunnel -p minikube-"
  else
    echo "❌ No tunnels running"
  fi
}


# -----------------------------------------------------------------------------
# Start/destroy functions
# -----------------------------------------------------------------------------
start() {
  echo "🧹 Cleaning up stale tunnels/proxies..."
  kill_minikube_tunnels

  echo "🚀 Starting Minikube clusters..."
  for profile in "${!CLUSTERS[@]}"; do
    read -r cpu mem service_cidr <<< "${CLUSTERS[$profile]}"
    start_cluster "$profile" "$cpu" "$mem" "$service_cidr"
  done

  echo "✅ All clusters ready!"

  if [[ -n "${MANAGEMENT_PROFILE:-}" ]] && minikube status -p "$MANAGEMENT_PROFILE" >/dev/null 2>&1; then
    kubectl config use-context "$MANAGEMENT_PROFILE"
  fi

  minikube profile list
}

destroy() {
  echo "🧹 Stopping Minikube clusters..."

  kill_minikube_tunnels
  delete_minikube_clusters
}


# -----------------------------------------------------------------------------
# Main entry point
# -----------------------------------------------------------------------------
case "${1:-start}" in
  start) start ;;
  destroy) destroy ;;
  tunnels) list_minikube_tunnels ;;

  *)
    echo "Usage: $0 [start|destroy|tunnels]"
    exit 1
    ;;
esac
