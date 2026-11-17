#!/usr/bin/env bash
# Deploy the notes app to AWS Emulator. Refuses to run against anything that
# isn't a local emulator, so a missing env var can't deploy to a real account.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/emulator-env.sh "${1:-9297}"

case "${AWS_ENDPOINT_URL:-}" in
  https://127.0.0.1:*) ;;
  *) echo "AWS_ENDPOINT_URL is not a local emulator. Stopping." >&2; exit 1 ;;
esac
if [ "$(aws sts get-caller-identity --query Account --output text)" != "000000000000" ]; then
  echo "This isn't the emulator's account. Stopping." >&2; exit 1
fi

terraform -chdir=terraform init -input=false >/dev/null
terraform -chdir=terraform apply -auto-approve -input=false
SITE="$(terraform -chdir=terraform output -raw site_url)"
echo
echo "Open in a browser:  ${SITE/https:/http:}/index.html"
echo "Or with curl:       curl --cacert \$AWS_CA_BUNDLE $SITE/api/notes"
