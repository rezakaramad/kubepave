#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# check-dependencies.sh
#
# Ensures all required CLI tools for the platform bootstrap are installed.
# Fails fast if any dependency (minikube, kubectl, helm, vault, jq, etc.)
# is missing to prevent runtime errors during setup.
# -----------------------------------------------------------------------------

echo "🔍 Checking required dependencies..."

# -----------------------------------------------------------------------------
# Dependencies (cmd|hint)
# -----------------------------------------------------------------------------

DEPENDENCIES=(
  # Minikube and Kubernetes
  "minikube|https://minikube.sigs.k8s.io/docs/start/"
  "kubectl|https://kubernetes.io/docs/tasks/tools/"
  "virsh|Install libvirt (e.g. apt install qemu-kvm libvirt-daemon-system)"

  # Charts
  "helm|https://helm.sh/docs/intro/install/"
  "yq|https://github.com/mikefarah/yq"
  "curl|https://curl.se/download.html"
  "base64|coreutils package"

  # Environment
  "jq|https://stedolan.github.io/jq/"
  "vault|https://developer.hashicorp.com/vault/downloads"
  "pass|https://www.passwordstore.org/"
  "ss|iproute2 package"
  "certutil|libnss3-tools"

  # DNS stack (NEW / IMPORTANT)
  "dnsmasq|apt install dnsmasq"
  "nmcli|network-manager package (apt install network-manager)"
  "dig|dnsutils package (apt install dnsutils)"
  "resolvectl|systemd-resolved (usually preinstalled)"

  # Containers
  "docker|https://docs.docker.com/engine/install/"

  # Keycloak
  "kcadm.sh|bundled with Keycloak"
)

missing=()


# -----------------------------------------------------------------------------
# Check function
# -----------------------------------------------------------------------------
check() {
  local cmd="$1"
  local hint="$2"

  if command -v "$cmd" >/dev/null 2>&1; then
    printf "   ✅ %-12s\n" "$cmd"
  else
    printf "   ❌ %-12s\n" "$cmd"
    missing+=("$cmd|$hint")
  fi
}


# -----------------------------------------------------------------------------
# Run checks
# -----------------------------------------------------------------------------
for entry in "${DEPENDENCIES[@]}"; do
  IFS="|" read -r cmd hint <<< "$entry"
  check "$cmd" "$hint"
done


# -----------------------------------------------------------------------------
# Result
# -----------------------------------------------------------------------------
if ((${#missing[@]} > 0)); then
  echo ""
  error "Missing required tools:"
  echo ""

  for entry in "${missing[@]}"; do
    IFS="|" read -r cmd hint <<< "$entry"
    printf "   - %-12s → %s\n" "$cmd" "$hint"
  done

  echo ""
  echo "Install them and re-run bootstrap."
  exit 1
fi

echo "✅ All dependencies installed"
