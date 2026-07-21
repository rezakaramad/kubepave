#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# check-dependencies.sh
#
# Ensures all required CLI tools for the kind platform bootstrap are installed.
# Fails fast if any dependency (kind, kubectl, helm, jq, etc.) is missing to
# prevent runtime errors during setup.
# -----------------------------------------------------------------------------

echo "🔍 Checking required dependencies..."

# -----------------------------------------------------------------------------
# Dependencies (cmd|hint)
# -----------------------------------------------------------------------------

DEPENDENCIES=(
  # Kubernetes and containers
  "docker|https://docs.docker.com/engine/install/"
  "kind|https://kind.sigs.k8s.io/docs/user/quick-start/#installation"
  "kubectl|https://kubernetes.io/docs/tasks/tools/"

  # Charts
  "helm|https://helm.sh/docs/intro/install/"

  # Certificates / trust stores
  "openssl|openssl package"
  "keytool|bundled with a JDK/JRE (e.g. apt install default-jre)"
  "certutil|libnss3-tools"

  # Secrets (pass decrypts credentials via GPG)
  "pass|https://www.passwordstore.org/"
  "gpg|https://gnupg.org/download/"

  # DNS (systemd-resolved drop-in is written via sudo)
  "dig|dnsutils package (apt install dnsutils)"
  "sudo|sudo package"

  # Helpers
  "jq|https://stedolan.github.io/jq/"
  "python3|python3 package"
  "base64|coreutils package"
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
  echo "❌ Missing required tools:"
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
