#!/usr/bin/env bash
# Ensure CloudFront rewrites /lineup/ → /lineup/index.html (S3 REST + OAC has no dir indexes).
# Idempotent: if the LIVE function is already on the distribution, exit 0.
# GitHub OIDC may lack cloudfront:CreateFunction — in that case we keep shipping
# after a one-time local attach (this script with admin/SSO creds).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
set -a && source "${ROOT}/infra/deploy.env" && set +a

FN_NAME="jamzilla-directory-index"
FN_FILE="${ROOT}/infra/cloudfront-directory-index.js"
DIST_ID="${CLOUDFRONT_DISTRIBUTION_ID}"

already_associated() {
  aws cloudfront get-distribution-config --id "${DIST_ID}" \
    --query "DistributionConfig.DefaultCacheBehavior.FunctionAssociations.Items[?contains(FunctionARN, \`${FN_NAME}\`)].FunctionARN" \
    --output text 2>/dev/null | grep -q "${FN_NAME}"
}

if already_associated; then
  echo "CloudFront already has ${FN_NAME} on ${DIST_ID} — skip attach."
  exit 0
fi

echo "Publishing CloudFront Function ${FN_NAME}"

if ! OUT="$(aws cloudfront describe-function --name "${FN_NAME}" 2>&1)"; then
  if echo "${OUT}" | grep -qi AccessDenied; then
    echo "WARN: no permission to manage CloudFront Functions, and ${FN_NAME} is not on the distribution yet." >&2
    echo "Run infra/ensure-directory-index.sh once with admin credentials, then redeploy." >&2
    exit 1
  fi
  # Not found — create
  if ! aws cloudfront create-function \
    --name "${FN_NAME}" \
    --function-config 'Comment="Rewrite directory URLs to index.html",Runtime=cloudfront-js-2.0' \
    --function-code "fileb://${FN_FILE}"; then
    echo "WARN: CreateFunction failed. Run this script locally with broader IAM, then redeploy." >&2
    exit 1
  fi
else
  ETAG="$(aws cloudfront describe-function --name "${FN_NAME}" --query 'ETag' --output text)"
  aws cloudfront update-function \
    --name "${FN_NAME}" \
    --if-match "${ETAG}" \
    --function-config 'Comment="Rewrite directory URLs to index.html",Runtime=cloudfront-js-2.0' \
    --function-code "fileb://${FN_FILE}" >/dev/null
fi

ETAG="$(aws cloudfront describe-function --name "${FN_NAME}" --query 'ETag' --output text)"
aws cloudfront publish-function --name "${FN_NAME}" --if-match "${ETAG}" >/dev/null

FN_ARN="$(aws cloudfront describe-function --name "${FN_NAME}" --stage LIVE --query 'FunctionSummary.FunctionMetadata.FunctionARN' --output text)"
echo "Function LIVE: ${FN_ARN}"

TMP="$(mktemp)"
trap 'rm -f "${TMP}"' EXIT
aws cloudfront get-distribution-config --id "${DIST_ID}" > "${TMP}"
DIST_ETAG="$(python3 - <<'PY' "${TMP}"
import json, sys
doc = json.load(open(sys.argv[1]))
print(doc["ETag"])
PY
)"
python3 - <<'PY' "${TMP}" "${FN_ARN}"
import json, sys
path, fn_arn = sys.argv[1], sys.argv[2]
doc = json.load(open(path))
cfg = doc["DistributionConfig"]
cfg["DefaultCacheBehavior"]["FunctionAssociations"] = {
    "Quantity": 1,
    "Items": [
        {
            "FunctionARN": fn_arn,
            "EventType": "viewer-request",
        }
    ],
}
json.dump(cfg, open(path, "w"))
PY

echo "Associating function on distribution ${DIST_ID} (If-Match ${DIST_ETAG})"
aws cloudfront update-distribution \
  --id "${DIST_ID}" \
  --if-match "${DIST_ETAG}" \
  --distribution-config "file://${TMP}" \
  --query 'Distribution.Status' \
  --output text

echo "CloudFront update submitted — wait for Deployed, then invalidate."
