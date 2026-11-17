# Source this to point the AWS CLI, SDKs and Terraform at AWS Emulator.
#   source scripts/emulator-env.sh [port]
# With no port it keeps the emulator this shell already points at, or 9297.
# It removes any real AWS keys from this shell first, so nothing you run here
# can reach a real account by mistake.
if [ -n "${1:-}" ]; then
  PORT="$1"
else
  case "${AWS_ENDPOINT_URL:-}" in
    https://127.0.0.1:*) PORT="${AWS_ENDPOINT_URL##*:}" ;;
    *) PORT=9297 ;;
  esac
fi
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE
export AWS_ENDPOINT_URL="https://127.0.0.1:${PORT}"
export AWS_SHARED_CREDENTIALS_FILE="$HOME/.aws/emulator/${PORT}/emulator_credentials"
export AWS_CONFIG_FILE="$HOME/.aws/emulator/${PORT}/config"
export AWS_CA_BUNDLE="$HOME/.aws/emulator/${PORT}/ca.pem"
export AWS_EC2_METADATA_DISABLED=true
export AWS_DISABLE_HOST_PREFIX_INJECTION=true
export AWS_REGION=us-east-1
export AWS_DEFAULT_REGION=us-east-1
echo "AWS points at the emulator on port ${PORT}: $(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo 'not running?')"
