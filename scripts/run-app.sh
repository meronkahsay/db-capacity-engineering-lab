#!/usr/bin/env bash
# =============================================================================
# scripts/run-app.sh — real app-container runtime for the LocalStack rehost.
#
# Per Rob's 2026-08-21 clarification: LocalStack's Hobby/free tier gives a
# mock EC2 only (RunInstances succeeds, no backing Docker container --
# confirmed directly via `awslocal ec2 describe-images --owners self`
# returning empty even after a real docker build+tag). EC2 is graded as IaC
# (apply it, it shows in the plan), not as the runtime. The real runtime for
# /healthz, /readyz, make verify, and incident replay is this container,
# wired to the same Secrets Manager secret + Aiven database the Terraform
# provisions -- same credentials path the EC2 user-data would have used
# (see terraform/modules/service/templates/user-data.sh.tftpl in the group
# repo), just run directly instead of via a mock instance.
#
# Prereqs: `tofu apply` has already run in terraform/ (secret_arn + db_endpoint
# outputs must exist), LocalStack is up, and the app image is built.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TF_DIR="$REPO_ROOT/terraform"

IMAGE_NAME="${IMAGE_NAME:-capacity-api:local}"
CONTAINER_NAME="${CONTAINER_NAME:-capacity-api-runtime}"
APP_PORT="${APP_PORT:-3000}"
AWS_ENDPOINT_URL="${AWS_ENDPOINT_URL:-http://localhost.localstack.cloud:4566}"
AWS_REGION="${AWS_REGION:-us-east-1}"

echo "==> Reading secret_arn / db_endpoint / db_port from terraform outputs..."
cd "$TF_DIR"
SECRET_ARN="$(tofu output -raw secret_arn)"
DB_ENDPOINT="$(tofu output -raw db_endpoint)"
# db_port isn't a root-module output (only db_endpoint/secret_arn are) --
# it's the same Aiven port already passed into terraform as TF_VAR_aiven_port.
DB_PORT="${TF_VAR_aiven_port:?TF_VAR_aiven_port must be set (same value used for the tofu apply)}"

if [ -z "$SECRET_ARN" ] || [ "$SECRET_ARN" = "null" ]; then
  echo "ERROR: secret_arn output is empty -- run 'tofu apply' in terraform/ first." >&2
  exit 1
fi

echo "    secret_arn:  $SECRET_ARN"
echo "    db_endpoint: $DB_ENDPOINT:$DB_PORT"

echo "==> Building app image ($IMAGE_NAME)..."
docker build --tag "$IMAGE_NAME" "$REPO_ROOT/api"

echo "==> Removing any previous $CONTAINER_NAME container..."
docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

echo "==> Starting $CONTAINER_NAME on :$APP_PORT..."
# --network host would be simpler for reaching LocalStack, but macOS/Codespace
# Docker doesn't support host networking the same way Linux does -- use the
# LocalStack DNS hostname (localhost.localstack.cloud) which resolves inside
# the container the same way it does in EC2 user-data on LocalStack.
docker run -d \
  --name "$CONTAINER_NAME" \
  --add-host=localhost.localstack.cloud:host-gateway \
  -p "$APP_PORT:3000" \
  -e "DB_SECRET_ARN=$SECRET_ARN" \
  -e "DB_HOST=$DB_ENDPOINT" \
  -e "DB_PORT=$DB_PORT" \
  -e "AWS_ENDPOINT_URL=$AWS_ENDPOINT_URL" \
  -e "AWS_REGION=$AWS_REGION" \
  -e "AWS_ACCESS_KEY_ID=test" \
  -e "AWS_SECRET_ACCESS_KEY=test" \
  -e "PORT=3000" \
  -v "$TF_DIR/aiven-ca.pem:/etc/app/db-ca.pem:ro" \
  -e "DB_CA_CERT_PATH=/etc/app/db-ca.pem" \
  "$IMAGE_NAME"

echo "==> Waiting for the container to come up..."
for i in $(seq 1 15); do
  if curl -sf "http://localhost:$APP_PORT/healthz" >/dev/null 2>&1; then
    echo "==> /healthz is up."
    break
  fi
  sleep 1
done

echo "==> /healthz:"
curl -si "http://localhost:$APP_PORT/healthz" || true
echo
echo "==> /readyz:"
curl -si "http://localhost:$APP_PORT/readyz" || true
echo
echo "==> Done. Logs: docker logs -f $CONTAINER_NAME"
