#!/usr/bin/env bash
# Install on OpenShift Local. Same process as ./deploy/deploy.sh crc.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${here}/deploy.sh" crc
