#!/usr/bin/env bash
# Deploy a Strongly app from a local bundle via the REST API, then wait for it
# to be live. Requires: curl, jq, and a zip of your app (with a Dockerfile).
#
#   HOST=https://app.strongly.ai \
#   STRONGLY_API_KEY=sk-... \
#   ./deploy-app.sh my-app ./bundle.zip
#
# Scopes needed on the API key: apps:write, apps:deploy.
set -euo pipefail

NAME="${1:?usage: deploy-app.sh <name> <bundle.zip>}"
BUNDLE="${2:?usage: deploy-app.sh <name> <bundle.zip>}"
HOST="${HOST:?set HOST to your Strongly host, e.g. https://app.strongly.ai}"
: "${STRONGLY_API_KEY:?set STRONGLY_API_KEY (Settings -> API Keys)}"

api() { curl -fsS -H "X-API-Key: $STRONGLY_API_KEY" "$@"; }

echo "==> Creating app '$NAME' and uploading $BUNDLE"
APP_ID=$(api -F "name=$NAME" \
             -F 'resources={"memory":"1Gi","cpu":"500m"}' \
             -F "file=@${BUNDLE};type=application/zip" \
             "$HOST/api/v1/apps/upload" | jq -r '.data._id')
echo "    app id: $APP_ID"

echo "==> Deploying (builds the image, creates the deployment)"
api -X POST "$HOST/api/v1/apps/$APP_ID/deploy" >/dev/null

echo "==> Waiting for the image build to finish"
while true; do
  BS=$(api "$HOST/api/v1/apps/$APP_ID/build-status" | jq -r '.data.status // .data')
  echo "    build: $BS"
  case "$BS" in
    completed) break ;;
    failed)    echo "!! build failed — logs:"; api "$HOST/api/v1/apps/$APP_ID/build-logs?level=error" | jq -r '.data'; exit 1 ;;
    *)         sleep 10 ;;
  esac
done

echo "==> Waiting for the pod to be healthy"
for _ in $(seq 1 60); do
  ST=$(api "$HOST/api/v1/apps/$APP_ID/status" | jq -r '.data.status // .data.phase // .data')
  echo "    pod: $ST"
  case "$ST" in
    running|Running|healthy|Healthy) echo "==> App is live: $APP_ID"; exit 0 ;;
    *) sleep 10 ;;
  esac
done

echo "!! App did not reach a running state in time — check: $HOST/api/v1/apps/$APP_ID/status" >&2
exit 1
