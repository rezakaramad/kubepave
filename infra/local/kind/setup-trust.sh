#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=libs/common.sh
source "$DIR/libs/common.sh"
# shellcheck source=libs/utils.sh
source "$DIR/libs/utils.sh"

MGMT_CONTEXT="$(kind_context management)"


# ----------------------------------------------------------------------------
# Trust self-signed CA certificate from Vault in local trust stores
# (Java, browser, system) and distribute to workload clusters.
# ----------------------------------------------------------------------------
trust_self_signed_ca_certificate() {
  BASE_DIR="$HOME/.local/share/rezakara"
  CA_FILE="$BASE_DIR/ca.crt"
  CERT_FILE="$BASE_DIR/tls.crt"
  KEY_FILE="$BASE_DIR/tls.key"

  JAVA_ALIAS="rezakara-root-ca"
  TRUSTSTORE="$BASE_DIR/java-truststore.jks"
  TRUSTSTORE_PASS="changeit"

  NSS_DIR="$HOME/.pki/nssdb"
  NSS_DB="sql:$NSS_DIR"
  NSS_NAME="RezaKara Root CA"
  NSS_PWFILE="$NSS_DIR/.nss-pwfile"

  SYS_CA_FILE="/usr/local/share/ca-certificates/rezakara-demo.crt"
  # No Keycloak in the kind setup — verify against Vault's TLS endpoint instead.
  VERIFY_HOST="vault.mgmt.rezakara.demo"

  mkdir -p "$BASE_DIR"

  log "Pulling certificates from the root-ca Secret..."

  kubectl --context "$MGMT_CONTEXT" -n "$PLATFORM_NAMESPACE" \
    get secret root-ca -o jsonpath='{.data.ca\.crt}' | base64 -d > "$CA_FILE"

  kubectl --context "$MGMT_CONTEXT" -n "$PLATFORM_NAMESPACE" \
    get secret root-ca -o jsonpath='{.data.tls\.crt}' | base64 -d > "$CERT_FILE"

  kubectl --context "$MGMT_CONTEXT" -n "$PLATFORM_NAMESPACE" \
    get secret root-ca -o jsonpath='{.data.tls\.key}' | base64 -d > "$KEY_FILE"

  chmod 600 "$KEY_FILE"

  log "Verifying certificate files..."

  if ! openssl x509 -in "$CA_FILE" -noout >/dev/null 2>&1; then
    err "Invalid CA certificate returned from Vault"
    exit 1
  fi

  if ! openssl x509 -in "$CERT_FILE" -noout >/dev/null 2>&1; then
    err "Invalid TLS certificate returned from Vault"
    exit 1
  fi

  if ! openssl rsa -in "$KEY_FILE" -check -noout >/dev/null 2>&1; then
    err "Invalid TLS key returned from Vault"
    exit 1
  fi

  log "Verifying certificate is a CA..."

  if ! openssl x509 -in "$CA_FILE" -noout -ext basicConstraints 2>/dev/null | grep -qi 'CA:TRUE'; then
    err "Certificate is not a CA"
    openssl x509 -in "$CA_FILE" -noout -subject -issuer || true
    exit 1
  fi

  ok "Certificate is a CA"

  log "Verifying CA self-signature..."

  if ! openssl verify -CAfile "$CA_FILE" "$CA_FILE" >/dev/null 2>&1; then
    err "CA self-verification failed"
    exit 1
  fi

  ok "CA self-verification passed"

  log "Verifying CA signs ${VERIFY_HOST}..."

  if ! timeout 8 openssl s_client \
        -connect "${VERIFY_HOST}:443" \
        -servername "$VERIFY_HOST" \
        -CAfile "$CA_FILE" \
        -verify_return_error \
        </dev/null >/dev/null 2>&1
  then
    err "CA does NOT sign the server certificate!"
    echo "Possible causes:"
    echo "  - cert-manager CA rotated (re-run setup-trust.sh)"
    echo "  - Wrong hostname"
    echo "  - Traefik TLS not enabled / wrong DNS"
    exit 1
  fi

  ok "CA correctly signs the server certificate"

  # --------------------------------------------------------------------------
  # Java truststore
  # --------------------------------------------------------------------------
  log "Updating Java truststore..."

  keytool -delete -alias "$JAVA_ALIAS" \
    -keystore "$TRUSTSTORE" \
    -storepass "$TRUSTSTORE_PASS" 2>/dev/null || true

  keytool -importcert \
    -alias "$JAVA_ALIAS" \
    -file "$CA_FILE" \
    -keystore "$TRUSTSTORE" \
    -storepass "$TRUSTSTORE_PASS" \
    -noprompt

  ok "Java truststore updated"

  # --------------------------------------------------------------------------
  # Browser trust (NSS)
  # --------------------------------------------------------------------------
  log "Updating browser trust (NSS)..."

  mkdir -p "$NSS_DIR"
  : > "$NSS_PWFILE"
  chmod 600 "$NSS_PWFILE"

  if [[ ! -f "$NSS_DIR/cert9.db" ]]; then
    certutil -d "$NSS_DB" -N --empty-password 2>/dev/null || true
  fi

  certutil -d "$NSS_DB" -D -n "$NSS_NAME" -f "$NSS_PWFILE" 2>/dev/null || true
  certutil -d "$NSS_DB" -A -t "C,," -n "$NSS_NAME" -i "$CA_FILE" -f "$NSS_PWFILE"

  ok "Browser CA updated (restart browser to pick it up)"

  # --------------------------------------------------------------------------
  # System trust store
  # --------------------------------------------------------------------------
  log "Updating system trust store..."

  sudo install -m 0644 "$CA_FILE" "$SYS_CA_FILE"
  sudo update-ca-certificates --fresh >/dev/null 2>&1 || true

  if [[ ! -f "$SYS_CA_FILE" ]]; then
    err "Failed to install CA into system trust directory"
    exit 1
  fi

  ok "System trust files updated"

  export JAVA_TOOL_OPTIONS="-Djavax.net.ssl.trustStore=$TRUSTSTORE -Djavax.net.ssl.trustStorePassword=$TRUSTSTORE_PASS"

  echo ""
  ok "All local trust stores refreshed"
  echo "To persist Java trust across shells, add to your shell profile:"
  echo "  set -x JAVA_TOOL_OPTIONS \"$JAVA_TOOL_OPTIONS\""

  # --------------------------------------------------------------------------
  # Seed CA trust into workload clusters
  # --------------------------------------------------------------------------
  log "Seeding CA trust into workload clusters..."

  get_kind_tenant_clusters | while IFS= read -r cluster; do
    local context
    context="$(kind_context "$cluster")"

    log "Bootstrapping trust into $cluster..."

    kubectl --context "$context" -n "$PLATFORM_NAMESPACE" \
      create secret tls root-ca \
      --cert="$CERT_FILE" \
      --key="$KEY_FILE" \
      --dry-run=client -o json \
      | jq '.data."ca.crt" = $ca | .type = "kubernetes.io/tls"' \
        --arg ca "$(base64 -w0 "$CA_FILE")" \
      | kubectl --context "$context" apply -f -
  done

  ok "Root CA secret distributed to workload clusters"
}


# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
main() {
  trust_self_signed_ca_certificate

  echo ""
  ok "Trust setup complete"
}

main "$@"
