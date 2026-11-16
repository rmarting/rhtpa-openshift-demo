#!/usr/bin/env bash
# Install the RHDA backend on OpenShift Local. Same process as ./deploy/deploy-rhda.sh crc.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${here}/deploy-rhda.sh" crc
