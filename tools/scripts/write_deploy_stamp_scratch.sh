#!/usr/bin/env bash
set -euo pipefail

STAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

cat > scratch_deploy_stamp.u <<EOF
turbo.service.deployStamp = "$STAMP"
EOF

echo "Wrote scratch_deploy_stamp.u with stamp: $STAMP"
