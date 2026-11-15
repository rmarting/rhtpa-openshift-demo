#!/usr/bin/env bash
# Install Keycloak and Red Hat Trusted Profile Analyzer.
# Usage: ./deploy/deploy.sh crc|ocp
# The crc and ocp scripts are the same entry with the target already chosen.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NS="${NAMESPACE:-trusted-profile-analyzer}"
platform="${1:-}"
OCP_WORK=""

usage() {
  echo "Usage: ./deploy/deploy.sh crc|ocp" >&2
  echo "       ./deploy/deploy-crc.sh" >&2
  echo "       ./deploy/deploy-ocp.sh" >&2
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

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Install $1 and run this script again." >&2
    exit 1
  fi
}

need oc
need python3

if ! oc whoami >/dev/null 2>&1; then
  echo "oc is not logged in. Log in as cluster-admin and run this script again." >&2
  if [[ "$platform" == "crc" ]]; then
    echo "  crc console --credentials" >&2
    echo "  oc login -u kubeadmin https://api.crc.testing:6443" >&2
  fi
  exit 1
fi

if ! oc auth can-i create subscriptions.operators.coreos.com --all-namespaces >/dev/null; then
  echo "The current user ($(oc whoami)) cannot install operators. Log in as cluster-admin." >&2
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
  echo "Run ./deploy/deploy.sh ocp for a standard OpenShift cluster." >&2
  exit 1
fi
if [[ "$platform" == "ocp" && "$domain" == "apps-crc.testing" ]]; then
  echo "This cluster is OpenShift Local." >&2
  echo "Run ./deploy/deploy.sh crc." >&2
  exit 1
fi

if [[ "$platform" == "crc" ]]; then
  echo
  echo "Node capacity (OpenShift Local should be about 12 CPUs and 32 GiB):"
  oc get nodes -o custom-columns=NAME:.metadata.name,CPU:.status.allocatable.cpu,MEMORY:.status.allocatable.memory
fi

render_ocp() {
  OCP_WORK="$(mktemp -d)"
  ln -s "${ROOT}/base" "${OCP_WORK}/base"
  cp -a "${ROOT}/ocp/." "${OCP_WORK}/ocp/"
  find "${OCP_WORK}/ocp" -type f -exec sed -i "s|__INGRESS_DOMAIN__|${domain}|g" {} +
  if grep -R -q "__INGRESS_DOMAIN__" "${OCP_WORK}/ocp"; then
    echo "Failed to render the ingress domain into the ocp overlay." >&2
    exit 1
  fi
}

if [[ "$platform" == "ocp" ]]; then
  render_ocp
fi

stage_path() {
  local stage="$1"
  case "$stage" in
    00-operators|10-database)
      echo "${ROOT}/base/${stage}"
      ;;
    *)
      if [[ "$platform" == "crc" ]]; then
        echo "${ROOT}/crc/${stage}"
      else
        echo "${OCP_WORK}/ocp/${stage}"
      fi
      ;;
  esac
}

apply_stage() {
  local stage="$1"
  local path
  path="$(stage_path "$stage")"
  echo "  oc apply -k ${path}"
  oc apply -k "$path"
}

echo
echo "Waiting for the redhat-operators catalog"
catalog_ready=0
for _ in $(seq 1 30); do
  state="$(oc get catalogsource redhat-operators -n openshift-marketplace \
    -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null || true)"
  echo "  redhat-operators: ${state:-absent}"
  if [[ "$state" == "READY" ]]; then
    catalog_ready=1
    break
  fi
  sleep 10
done
if [[ "$catalog_ready" != 1 ]]; then
  if [[ "$platform" == "crc" ]]; then
    echo "catalogsource/redhat-operators is not READY. Start OpenShift Local with a pull secret from https://console.redhat.com/openshift/create/local" >&2
  else
    echo "catalogsource/redhat-operators is not READY. This cluster cannot install the RHTPA and Keycloak operators yet." >&2
  fi
  oc get catalogsource -n openshift-marketplace >&2 || true
  exit 1
fi

wait_packagemanifest() {
  local pkg="$1"
  local attempt
  for attempt in $(seq 1 30); do
    if oc get packagemanifest "$pkg" -n openshift-marketplace >/dev/null 2>&1; then
      return 0
    fi
    sleep 10
  done
  echo "PackageManifest ${pkg} did not appear in openshift-marketplace." >&2
  exit 1
}

echo
echo "Checking operator channels"
wait_packagemanifest rhtpa-operator
wait_packagemanifest rhbk-operator

echo "rhtpa-operator channels:"
oc get packagemanifest rhtpa-operator -n openshift-marketplace \
  -o jsonpath='{range .status.channels[*]}{.name}{"\n"}{end}'
echo "rhbk-operator channels:"
oc get packagemanifest rhbk-operator -n openshift-marketplace \
  -o jsonpath='{range .status.channels[*]}{.name}{"\n"}{end}'

python3 - <<'PY'
import json, subprocess, sys
def manifest(name):
    raw = subprocess.check_output(["oc","get","packagemanifest",name,"-n","openshift-marketplace","-o","json"])
    return json.loads(raw)
rhtpa = manifest("rhtpa-operator")
channels = {c["name"]: [e["name"] for e in c.get("entries", [])] for c in rhtpa["status"]["channels"]}
if "stable-v3" not in channels:
    sys.exit("rhtpa-operator has no stable-v3 channel. OperatorHub's default channel is the 2.x line. This repository requires stable-v3.")
if "rhtpa-operator.v3.1.1" not in channels["stable-v3"]:
    print("stable-v3 entries:")
    print("\n".join(channels["stable-v3"]))
    sys.exit("rhtpa-operator.v3.1.1 is not in stable-v3. Remove spec.startingCSV from base/00-operators/subscription-rhtpa.yaml if your catalog no longer lists 3.1.1, then review the CSV you will install.")
rhbk = manifest("rhbk-operator")
rhbk_channels = [c["name"] for c in rhbk["status"]["channels"]]
if "stable-v26" not in rhbk_channels:
    print("rhbk-operator channels: " + ", ".join(rhbk_channels))
    sys.exit("Edit base/00-operators/subscription-rhbk.yaml and set spec.channel to a 26.x channel from the list above.")
print("Catalog has rhtpa-operator.v3.1.1 on stable-v3 and rhbk-operator on stable-v26.")
PY

approve() {
  local plans
  plans="$(oc get installplan -n "$NS" -o jsonpath='{range .items[?(@.spec.approved==false)]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
  [[ -z "$plans" ]] && return 0
  local plan
  while IFS= read -r plan; do
    [[ -z "$plan" ]] && continue
    echo "Approving InstallPlan ${plan}"
    oc patch installplan "$plan" -n "$NS" --type merge -p '{"spec":{"approved":true}}'
  done <<<"$plans"
}

echo
echo "Stage 1: operators"
apply_stage 00-operators

echo "Waiting for the CSVs (this can take several minutes)"
operators_ready=0
deadline=$((SECONDS + 900))
while (( SECONDS < deadline )); do
  approve
  total="$(oc get csv -n "$NS" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  succeeded="$(oc get csv -n "$NS" --no-headers 2>/dev/null | awk '$NF=="Succeeded"{c++} END{print c+0}')"
  echo "  CSVs Succeeded: ${succeeded} of ${total}"
  if [[ "${total}" -ge 2 && "${succeeded}" == "${total}" ]]; then
    operators_ready=1
    break
  fi
  sleep 10
done
if [[ "$operators_ready" != 1 ]]; then
  echo "Operators did not reach Succeeded. Current status:" >&2
  oc get csv,subscription,installplan -n "$NS" >&2 || true
  oc describe subscription rhtpa-operator rhbk-operator -n "$NS" >&2 || true
  exit 1
fi
oc get csv -n "$NS"

echo
echo "Stage 2: PostgreSQL and lab secrets"
apply_stage 10-database
oc wait --for=condition=Ready pod/rhtpa-postgresql-0 -n "$NS" --timeout=300s
oc wait --for=condition=Ready pod/keycloak-postgresql-0 -n "$NS" --timeout=300s

echo
echo "Stage 3: ingress CA"
NAMESPACE="$NS" "${ROOT}/deploy/import-router-ca.sh"

echo
echo "Stage 4: Keycloak (the first start often takes 5 to 10 minutes)"
apply_stage 20-keycloak
oc wait --for=condition=Ready keycloak/keycloak-sso -n "$NS" --timeout=900s

echo
echo "Stage 5: trustify realm, clients, and users"
apply_stage 30-realm
oc wait --for=condition=Done keycloakrealmimport/rhtpa -n "$NS" --timeout=900s

echo
echo "Stage 6: Trusted Profile Analyzer"
if ! oc get secret rhtpa-rhlw-creds -n "$NS" >/dev/null 2>&1; then
  echo "Secret ${NS}/rhtpa-rhlw-creds is missing." >&2
  echo "The Lightwell importers read the username and token from files in that Secret." >&2
  echo "Create it yourself (Kustomize does not), then run this script again. See README section 4.6." >&2
  exit 1
fi
apply_stage 40-rhtpa
oc wait --for=condition=Available deployment/server -n "$NS" --timeout=900s
oc wait --for=condition=Available deployment/importer -n "$NS" --timeout=900s

cat <<EOF

RHTPA is up.

  Console:  https://server-trusted-profile-analyzer.${domain}
  Keycloak: https://sso-trusted-profile-analyzer.${domain}
  Admin console (master realm): https://sso-trusted-profile-analyzer.${domain}/admin

Lab users, realm trustify:
  admin    / admin123456     administrator
  analyst  / analyst123456   read-only

Keycloak master administrator (bootstrap user):
  admin / admin123456

Change these passwords before anyone else can open the routes.

EOF
