#!/usr/bin/env bash
# Optional install of the Red Hat Dependency Analytics backend.
# Requires Keycloak and RHTPA from ./deploy/deploy.sh crc|ocp.
# Usage: ./deploy/deploy-rhda.sh crc|ocp
#        ./deploy/deploy-rhda-crc.sh
#        ./deploy/deploy-rhda-ocp.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NS="${NAMESPACE:-trusted-profile-analyzer}"
platform="${1:-}"
OCP_WORK=""

usage() {
  echo "Usage: ./deploy/deploy-rhda.sh crc|ocp" >&2
  echo "       ./deploy/deploy-rhda-crc.sh" >&2
  echo "       ./deploy/deploy-rhda-ocp.sh" >&2
}

case "$platform" in
  crc|ocp) ;;
  *) usage; exit 1 ;;
esac

cleanup() {
  if [[ -n "${OCP_WORK}" ]]; then
    rm -rf "${OCP_WORK}"
  fi
}
trap cleanup EXIT

if ! command -v oc >/dev/null 2>&1; then
  echo "Install oc and run this script again." >&2
  exit 1
fi

if ! oc whoami >/dev/null 2>&1; then
  echo "oc is not logged in. Log in as cluster-admin and run this script again." >&2
  if [[ "$platform" == "crc" ]]; then
    echo "  crc console --credentials" >&2
    echo "  oc login -u kubeadmin https://api.crc.testing:6443" >&2
  fi
  exit 1
fi

if ! oc auth can-i create deployments.apps -n "$NS" >/dev/null; then
  echo "The current user ($(oc whoami)) cannot create deployments in ${NS}." >&2
  exit 1
fi

domain="$(oc get ingresscontroller.operator.openshift.io default \
  -n openshift-ingress-operator \
  -o jsonpath='{.status.domain}')"
echo "Ingress domain: ${domain:-<empty>}"
if [[ -z "$domain" ]]; then
  echo "The default ingress controller has no status.domain." >&2
  exit 1
fi
if [[ ! "$domain" =~ ^[A-Za-z0-9.-]+$ ]]; then
  echo "Refusing to use ingress domain '${domain}'." >&2
  exit 1
fi
if [[ "$platform" == "crc" && "$domain" != "apps-crc.testing" ]]; then
  echo "This cluster's apps domain is ${domain}, not apps-crc.testing." >&2
  echo "Run ./deploy/deploy-rhda.sh ocp for a standard OpenShift cluster." >&2
  exit 1
fi
if [[ "$platform" == "ocp" && "$domain" == "apps-crc.testing" ]]; then
  echo "This cluster is OpenShift Local." >&2
  echo "Run ./deploy/deploy-rhda.sh crc." >&2
  exit 1
fi

echo
echo "Checking Keycloak, RHTPA, and the ingress CA"
missing=0
if ! oc get keycloak keycloak-sso -n "$NS" >/dev/null 2>&1; then
  echo "Keycloak keycloak-sso is missing in ${NS}. Install it with ./deploy/deploy.sh ${platform} first." >&2
  missing=1
fi
if ! oc get deployment server -n "$NS" >/dev/null 2>&1; then
  echo "RHTPA deployment/server is missing in ${NS}. Install it with ./deploy/deploy.sh ${platform} first." >&2
  missing=1
fi
if ! oc get secret oidc-cli -n "$NS" >/dev/null 2>&1; then
  echo "Secret ${NS}/oidc-cli is missing. The RHDA backend uses the cli client secret from that Secret." >&2
  missing=1
fi
if ! oc get configmap ingress-ca -n "$NS" >/dev/null 2>&1; then
  echo "ConfigMap ${NS}/ingress-ca is missing. Run ./deploy/import-router-ca.sh first." >&2
  missing=1
fi
if [[ "$missing" != 0 ]]; then
  exit 1
fi

render_ocp() {
  OCP_WORK="$(mktemp -d)"
  mkdir -p "${OCP_WORK}/ocp"
  ln -s "${ROOT}/base" "${OCP_WORK}/base"
  cp -a "${ROOT}/ocp/50-rhda" "${OCP_WORK}/ocp/50-rhda"
  find "${OCP_WORK}/ocp/50-rhda" -type f -exec sed -i "s|__INGRESS_DOMAIN__|${domain}|g" {} +
  if grep -R -q "__INGRESS_DOMAIN__" "${OCP_WORK}/ocp/50-rhda"; then
    echo "Failed to render the ingress domain into the RHDA overlay." >&2
    exit 1
  fi
}

if [[ "$platform" == "crc" ]]; then
  overlay="${ROOT}/crc/50-rhda"
else
  render_ocp
  overlay="${OCP_WORK}/ocp/50-rhda"
fi

echo
echo "Stage: Red Hat Dependency Analytics"
echo "  oc apply -k ${overlay}"
oc apply -k "$overlay"

echo "Waiting for PostgreSQL and Redis"
oc wait --for=condition=Available deployment/rhda-backend-postgresql -n "$NS" --timeout=300s
oc wait --for=condition=Available deployment/rhda-backend-redis -n "$NS" --timeout=300s

echo "Building rhda-backend from https://github.com/guacsec/trustify-dependency-analytics (ref v2.1.0)"
oc start-build bc/rhda-backend -n "$NS" --follow

echo "Waiting for the RHDA backend"
oc wait --for=condition=Available deployment/rhda-backend -n "$NS" --timeout=900s

route_host="$(oc get route rhda-backend -n "$NS" -o jsonpath='{.spec.host}')"

cat <<EOF

Red Hat Dependency Analytics is up.

  Backend URL: https://${route_host}

The IDE plugin sends SBOMs to that URL. The backend calls RHTPA at
https://server.${NS}.svc:443 and signs in to Keycloak as the cli client
on https://sso-trusted-profile-analyzer.${domain}/realms/trustify.

VS Code setting:

  "redhat.dependency.analytics.exhort.backendUrl": "https://${route_host}"

EOF
