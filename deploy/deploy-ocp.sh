#!/usr/bin/env bash
# Install on a standard OpenShift cluster. Same process as ./deploy/deploy.sh ocp.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${here}/deploy.sh" ocp
