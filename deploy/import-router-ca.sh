#!/usr/bin/env bash
# Copy the cluster ingress CA into the RHTPA namespace.
# RHTPA uses it to trust the Keycloak route certificate.
set -euo pipefail

NAMESPACE="${NAMESPACE:-trusted-profile-analyzer}"
CONFIGMAP="${CONFIGMAP:-ingress-ca}"

if ! oc auth can-i get secrets -n openshift-ingress-operator >/dev/null; then
  echo "This command needs cluster-admin, so it can read secret/router-ca in openshift-ingress-operator." >&2
  exit 1
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

oc get secret router-ca -n openshift-ingress-operator -o jsonpath='{.data.tls\.crt}' | base64 -d >"$tmp"
if ! grep -q "BEGIN CERTIFICATE" "$tmp"; then
  echo "secret/router-ca did not contain a PEM certificate in tls.crt." >&2
  exit 1
fi

oc create configmap "$CONFIGMAP" \
  --namespace "$NAMESPACE" \
  --from-file=tls.crt="$tmp" \
  --dry-run=client \
  -o yaml | oc apply -f -

echo "ConfigMap ${NAMESPACE}/${CONFIGMAP} key tls.crt is the default ingress CA."
