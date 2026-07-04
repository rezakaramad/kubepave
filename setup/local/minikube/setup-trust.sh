#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=libs/common.sh
source "$DIR/libs/common.sh"
# shellcheck source=libs/utils.sh
source "$DIR/libs/utils.sh"

# ----------------------------------------------------------------------------
# Trust self-signed CA certificate from Vault in
# local trust stores (Java, browser, system) and distribute to tenant clusters
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
  KEYCLOAK_HOST="oidc.mgmt.rezakara.demo"

  mkdir -p "$BASE_DIR"

  echo "🔎 Checking ClusterSecretStore readiness..."

  READY=$(kubectl get clustersecretstore vault-local -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')

  if [[ "$READY" != "True" ]]; then
    echo "❌ ClusterSecretStore 'vault-local' is not ready"
    kubectl get clustersecretstore vault-local
    exit 1
  fi

  echo "✅ ClusterSecretStore is ready"

  echo "📥 Pull certificates from Vault"

  vault kv get -field=ca.crt local/management/pki > "$CA_FILE"
  vault kv get -field=tls.crt local/management/pki > "$CERT_FILE"
  vault kv get -field=tls.key local/management/pki > "$KEY_FILE"

  chmod 600 "$KEY_FILE"

  echo "📜 Verify certificate files"

  if ! openssl x509 -in "$CA_FILE" -noout >/dev/null 2>&1; then
    echo "❌ Invalid CA certificate returned from Vault"
    exit 1
  fi

  if ! openssl x509 -in "$CERT_FILE" -noout >/dev/null 2>&1; then
    echo "❌ Invalid TLS certificate returned from Vault"
    exit 1
  fi

  if ! openssl rsa -in "$KEY_FILE" -check -noout >/dev/null 2>&1; then
    echo "❌ Invalid TLS key returned from Vault"
    exit 1
  fi

  echo "🏛️  Verify certificate is a CA"

  if ! openssl x509 -in "$CA_FILE" -noout -ext basicConstraints 2>/dev/null | grep -qi 'CA:TRUE'; then
    echo "❌ Certificate is not a CA"
    openssl x509 -in "$CA_FILE" -noout -subject -issuer || true
    openssl x509 -in "$CA_FILE" -noout -ext basicConstraints || true
    exit 1
  fi

  echo "🟢 Certificate is a CA"

  echo "🔍 Verify CA self-signature"

  if ! openssl verify -CAfile "$CA_FILE" "$CA_FILE" >/dev/null 2>&1; then
    echo "❌ CA self-verification failed"
    exit 1
  fi

  echo "🟢 CA self-verification passed"

  echo "🔍 Verify CA signs $KEYCLOAK_HOST"

  if ! timeout 8 openssl s_client \
        -connect "${KEYCLOAK_HOST}:443" \
        -servername "$KEYCLOAK_HOST" \
        -CAfile "$CA_FILE" \
        -verify_return_error \
        </dev/null >/dev/null 2>&1
  then
    echo "❌ CA does NOT sign the server certificate!"
    echo "Possible causes:"
    echo "  - Wrong secret pushed to Vault"
    echo "  - cert-manager CA rotated"
    echo "  - Wrong hostname"
    echo "  - minikube tunnel not running / wrong /etc/hosts"
    exit 1
  fi

  echo "🟢 CA correctly signs the server certificate"

  echo "☕ Update Java truststore"

  keytool -delete -alias "$JAVA_ALIAS" \
    -keystore "$TRUSTSTORE" \
    -storepass "$TRUSTSTORE_PASS" 2>/dev/null || true

  keytool -importcert \
    -alias "$JAVA_ALIAS" \
    -file "$CA_FILE" \
    -keystore "$TRUSTSTORE" \
    -storepass "$TRUSTSTORE_PASS" \
    -noprompt

  keytool -list -v \
    -keystore "$TRUSTSTORE" \
    -storepass "$TRUSTSTORE_PASS" \
    -alias "$JAVA_ALIAS" | egrep "Owner:|Issuer:|SHA256:|BasicConstraints"

  echo "🟢 Java truststore updated"

  echo "🌐 Update browser trust"

  mkdir -p "$NSS_DIR"
  : > "$NSS_PWFILE"
  chmod 600 "$NSS_PWFILE"

  if [ ! -f "$NSS_DIR/cert9.db" ]; then
    certutil -d "$NSS_DB" -N --empty-password 2>/dev/null || true
  fi

  certutil -d "$NSS_DB" -D -n "$NSS_NAME" -f "$NSS_PWFILE" 2>/dev/null || true
  certutil -d "$NSS_DB" -A -t "C,," -n "$NSS_NAME" -i "$CA_FILE" -f "$NSS_PWFILE"

  echo "🟢 Browser CA updated (restart browser)"

  echo "🔐 Update system trust store"

  sudo install -m 0644 "$CA_FILE" "$SYS_CA_FILE"
  sudo update-ca-certificates --fresh >/dev/null 2>&1 || true

  if [[ ! -f "$SYS_CA_FILE" ]]; then
    echo "❌ Failed to install CA into system trust directory"
    exit 1
  fi

  echo "🟢 System trust files updated"

  export JAVA_TOOL_OPTIONS="-Djavax.net.ssl.trustStore=$TRUSTSTORE -Djavax.net.ssl.trustStorePassword=$TRUSTSTORE_PASS"

  echo
  echo "✅ All trust stores refreshed successfully"
  echo "To persist across shells run:"
  echo "echo 'export JAVA_TOOL_OPTIONS=\"$JAVA_TOOL_OPTIONS\"' >> ~/.bashrc"

  echo "🌐 Seeding CA trust into workload clusters..."

  get_minikube_tenant_profiles | while IFS= read -r profile; do
    echo "➡️  Bootstrap trust into $profile"

    kubectl --context "$profile" -n "$PLATFORM_NAMESPACE" create secret generic root-ca \
      --from-file=ca.crt="$CA_FILE" \
      --from-file=tls.crt="$CERT_FILE" \
      --from-file=tls.key="$KEY_FILE" \
      --dry-run=client -o yaml \
    | kubectl --context "$profile" apply -f -
  done

  echo "🔐 Root CA secret distributed to workload clusters."
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
main() {
  vault_login
  trust_self_signed_ca_certificate

  echo "✅ Trust setup complete"
}

main "$@"
