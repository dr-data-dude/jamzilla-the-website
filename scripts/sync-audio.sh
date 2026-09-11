#!/usr/bin/env bash
# Upload gitignored session cuts under audio/ to S3 and invalidate CloudFront.
# CI checkout has no audio/ (see .gitignore) — run this from a machine that has the MP3s.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"

# shellcheck disable=SC1091
set -a && source infra/deploy.env && set +a

if [[ ! -d audio ]] || ! compgen -G 'audio/*' > /dev/null; then
  echo "No files in ${ROOT}/audio — nothing to upload" >&2
  exit 1
fi

echo "Syncing audio/ → s3://${S3_BUCKET}/audio (Content-Type: audio/mpeg)"
aws s3 sync audio "s3://${S3_BUCKET}/audio" \
  --exclude '.DS_Store' \
  --content-type 'audio/mpeg' \
  --cache-control 'public, max-age=86400'

echo "Invalidating CloudFront /audio/*"
aws cloudfront create-invalidation \
  --distribution-id "${CLOUDFRONT_DISTRIBUTION_ID}" \
  --paths '/audio/*' \
  --query 'Invalidation.Id' \
  --output text

echo "Probe:"
for cut in audio/*.mp3; do
  name="$(basename "${cut}")"
  url="https://${DOMAIN}/audio/${name}"
  ct="$(curl -sS -I --max-time 20 "${url}" | tr -d '\r' | awk -F': ' 'tolower($1)=="content-type"{print $2; exit}')"
  echo "  ${url} → ${ct}"
done
