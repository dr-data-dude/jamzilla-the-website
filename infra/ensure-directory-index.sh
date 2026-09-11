#!/usr/bin/env bash
# Ensure CloudFront rewrites /lineup/ → /lineup/index.html (S3 REST + OAC has no dir indexes).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
set -a && source "${ROOT}/infra/deploy.env" && set +a

FN_NAME="jamzilla-directory-index"
FN_FILE="${ROOT}/infra/cloudfront-directory-index.js"
DIST_ID="${CLOUDFRONT_DISTRIBUTION_ID}"

echo "Publishing CloudFront Function ${FN_NAME}"

if aws cloudfront describe-function --name "${FN_NAME}" >/dev/null 2>&1; then
  ETAG="$(aws cloudfront describe-function --name "${FN_NAME}" --query 'ETag' --output text)"
  aws cloudfront update-function \
    --name "${FN_NAME}" \
    --if-match "${ETAG}" \
    --function-config 'Comment="Rewrite directory URLs to index.html",Runtime=cloudfront-js-2.0' \
    --function-code "fileb://${FN_FILE}" >/dev/null
else
  aws cloudfront create-function \
    --name "${FN_NAME}" \
    --function-config 'Comment="Rewrite directory URLs to index.html",Runtime=cloudfront-js-2.0' \
    --function-code "fileb://${FN_FILE}" >/dev/null
fi

ETAG="$(aws cloudfront describe-function --name "${FN_NAME}" --query 'ETag' --output text)"
aws cloudfront publish-function --name "${FN_NAME}" --if-match "${ETAG}" >/dev/null

FN_ARN="$(aws cloudfront describe-function --name "${FN_NAME}" --stage LIVE --query 'FunctionSummary.FunctionMetadata.FunctionARN' --output text)"
echo "Function LIVE: ${FN_ARN}"

TMP="$(mktemp)"
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

rm -f "${TMP}"
echo "CloudFront update submitted — wait for Deployed, then invalidate."
