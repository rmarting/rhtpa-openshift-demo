#!/usr/bin/env bash
# Install the RHDA backend on a standard OpenShift cluster. Same process as ./deploy/deploy-rhda.sh ocp.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${here}/deploy-rhda.sh" ocp
