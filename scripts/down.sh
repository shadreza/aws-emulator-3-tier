#!/usr/bin/env bash
# Remove the notes app from the emulator. Stopping the emulator also removes
# everything, because it keeps all state in memory.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/emulator-env.sh "${1:-9297}"
case "${AWS_ENDPOINT_URL:-}" in
  https://127.0.0.1:*) ;;
  *) echo "AWS_ENDPOINT_URL is not a local emulator. Stopping." >&2; exit 1 ;;
esac
terraform -chdir=terraform destroy -auto-approve -input=false
