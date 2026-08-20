#!/usr/bin/env bash
# One-time / repeatable AWS bootstrap for jamzilla-the-website.
# Private S3 + CloudFront OAC + ACM (us-east-1) + Route53 + GitHub OIDC role.
set -euo pipefail

REGION="${AWS_REGION:-eu-central-1}"
ACM_REGION="us-east-1"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
PROJECT="jamzilla-the-website"
DOMAIN="jamzilla.dr-data-dude.com"
BUCKET="${S3_BUCKET:-${PROJECT}-${ACCOUNT}}"
HOSTED_ZONE_ID="${HOSTED_ZONE_ID:-Z02311982Y816PZ0D3ZXL}"
GH_OWNER="${GH_OWNER:-dr-data-dude}"
GH_REPO="${GH_REPO:-jamzilla-the-website}"
ROLE_NAME="github-actions-${PROJECT}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEPLOY_ENV="${ROOT}/infra/deploy.env"

echo "==> account=${ACCOUNT} region=${REGION} domain=${DOMAIN}"
echo "==> bucket=${BUCKET}"

# ---------------------------------------------------------------------------
# S3 — private, no website endpoint (CloudFront REST origin + OAC)
# ---------------------------------------------------------------------------
echo "==> S3 bucket"
if ! aws s3api head-bucket --bucket "${BUCKET}" 2>/dev/null; then
  aws s3api create-bucket \
    --bucket "${BUCKET}" \
    --region "${REGION}" \
    --create-bucket-configuration LocationConstraint="${REGION}" >/dev/null
  aws s3api put-public-access-block \
    --bucket "${BUCKET}" \
    --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  aws s3api put-bucket-ownership-controls \
    --bucket "${BUCKET}" \
    --ownership-controls 'Rules=[{ObjectOwnership=BucketOwnerEnforced}]'
  aws s3api put-bucket-tagging \
    --bucket "${BUCKET}" \
    --tagging "TagSet=[{Key=Project,Value=${PROJECT}}]"
fi
echo "    s3://${BUCKET}"

# Seed the page so CloudFront has something to serve on first deploy.
aws s3 cp "${ROOT}/index.html" "s3://${BUCKET}/index.html" \
  --content-type "text/html; charset=utf-8" \
  --cache-control "public, max-age=60" >/dev/null
echo "    uploaded index.html"

# ---------------------------------------------------------------------------
# ACM — must be us-east-1 for CloudFront
# ---------------------------------------------------------------------------
echo "==> ACM certificate (${ACM_REGION})"
CERT_ARN="$(aws acm list-certificates --region "${ACM_REGION}" \
  --query "CertificateSummaryList[?DomainName=='${DOMAIN}'].CertificateArn | [0]" \
  --output text)"
if [[ -z "${CERT_ARN}" || "${CERT_ARN}" == "None" ]]; then
  CERT_ARN="$(aws acm request-certificate \
    --region "${ACM_REGION}" \
    --domain-name "${DOMAIN}" \
    --validation-method DNS \
    --tags Key=Project,Value="${PROJECT}" \
    --query CertificateArn --output text)"
  echo "    requested ${CERT_ARN}"
  sleep 8
else
  echo "    existing ${CERT_ARN}"
fi

# DNS validation CNAME into Route 53
for _ in $(seq 1 12); do
  VAL_NAME="$(aws acm describe-certificate --region "${ACM_REGION}" --certificate-arn "${CERT_ARN}" \
    --query "Certificate.DomainValidationOptions[0].ResourceRecord.Name" --output text)"
  VAL_VALUE="$(aws acm describe-certificate --region "${ACM_REGION}" --certificate-arn "${CERT_ARN}" \
    --query "Certificate.DomainValidationOptions[0].ResourceRecord.Value" --output text)"
  if [[ -n "${VAL_NAME}" && "${VAL_NAME}" != "None" && -n "${VAL_VALUE}" && "${VAL_VALUE}" != "None" ]]; then
    break
  fi
  sleep 3
done
if [[ -z "${VAL_NAME}" || "${VAL_NAME}" == "None" ]]; then
  echo "ACM validation record not ready yet — re-run bootstrap in a minute." >&2
  exit 1
fi

CHANGE_BATCH="$(python3 - <<PY
import json
print(json.dumps({
  "Comment": "ACM DNS validation for ${DOMAIN}",
  "Changes": [{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "${VAL_NAME}",
      "Type": "CNAME",
      "TTL": 300,
      "ResourceRecords": [{"Value": "${VAL_VALUE}"}]
    }
  }]
}))
PY
)"
aws route53 change-resource-record-sets \
  --hosted-zone-id "${HOSTED_ZONE_ID}" \
  --change-batch "${CHANGE_BATCH}" >/dev/null
echo "    validation CNAME upserted → ${VAL_NAME}"

echo "    waiting for certificate ISSUED…"
aws acm wait certificate-validated --region "${ACM_REGION}" --certificate-arn "${CERT_ARN}"
echo "    certificate ISSUED"

# ---------------------------------------------------------------------------
# CloudFront OAC + distribution
# ---------------------------------------------------------------------------
echo "==> CloudFront OAC"
OAC_ID="$(aws cloudfront list-origin-access-controls \
  --query "OriginAccessControlList.Items[?Name=='${PROJECT}-oac'].Id | [0]" \
  --output text)"
if [[ -z "${OAC_ID}" || "${OAC_ID}" == "None" ]]; then
  OAC_ID="$(aws cloudfront create-origin-access-control \
    --origin-access-control-config "{
      \"Name\": \"${PROJECT}-oac\",
      \"Description\": \"OAC for ${PROJECT}\",
      \"SigningProtocol\": \"sigv4\",
      \"SigningBehavior\": \"always\",
      \"OriginAccessControlOriginType\": \"s3\"
    }" \
    --query 'OriginAccessControl.Id' --output text)"
fi
echo "    OAC ${OAC_ID}"

DIST_ID="$(aws cloudfront list-distributions \
  --query "DistributionList.Items[?Comment=='${PROJECT}'].Id | [0]" \
  --output text 2>/dev/null || true)"
if [[ -z "${DIST_ID}" || "${DIST_ID}" == "None" ]]; then
  CALLER_REF="$(date +%s)-${PROJECT}"
  ORIGIN_DOMAIN="${BUCKET}.s3.${REGION}.amazonaws.com"
  cat > /tmp/jamzilla-cf-dist.json <<EOF
{
  "CallerReference": "${CALLER_REF}",
  "Comment": "${PROJECT}",
  "Enabled": true,
  "IsIPV6Enabled": true,
  "HttpVersion": "http2and3",
  "PriceClass": "PriceClass_100",
  "DefaultRootObject": "index.html",
  "Aliases": {
    "Quantity": 1,
    "Items": ["${DOMAIN}"]
  },
  "Origins": {
    "Quantity": 1,
    "Items": [{
      "Id": "s3-${PROJECT}",
      "DomainName": "${ORIGIN_DOMAIN}",
      "OriginAccessControlId": "${OAC_ID}",
      "S3OriginConfig": { "OriginAccessIdentity": "" },
      "ConnectionAttempts": 3,
      "ConnectionTimeout": 10
    }]
  },
  "DefaultCacheBehavior": {
    "TargetOriginId": "s3-${PROJECT}",
    "ViewerProtocolPolicy": "redirect-to-https",
    "AllowedMethods": {
      "Quantity": 2,
      "Items": ["GET", "HEAD"],
      "CachedMethods": { "Quantity": 2, "Items": ["GET", "HEAD"] }
    },
    "Compress": true,
    "CachePolicyId": "658327ea-f89d-4fab-a63d-7e88639e58f6",
    "ResponseHeadersPolicyId": "67f7725c-6f97-4210-82d7-5512b31e9d03"
  },
  "ViewerCertificate": {
    "ACMCertificateArn": "${CERT_ARN}",
    "SSLSupportMethod": "sni-only",
    "MinimumProtocolVersion": "TLSv1.2_2021"
  },
  "CustomErrorResponses": {
    "Quantity": 2,
    "Items": [
      {
        "ErrorCode": 403,
        "ResponsePagePath": "/index.html",
        "ResponseCode": "200",
        "ErrorCachingMinTTL": 0
      },
      {
        "ErrorCode": 404,
        "ResponsePagePath": "/index.html",
        "ResponseCode": "200",
        "ErrorCachingMinTTL": 0
      }
    ]
  }
}
EOF
  DIST_ID="$(aws cloudfront create-distribution \
    --distribution-config file:///tmp/jamzilla-cf-dist.json \
    --query 'Distribution.Id' --output text)"
  echo "    created distribution ${DIST_ID}"
else
  echo "    existing distribution ${DIST_ID}"
fi

CF_DOMAIN="$(aws cloudfront get-distribution --id "${DIST_ID}" \
  --query 'Distribution.DomainName' --output text)"
DIST_ARN="$(aws cloudfront get-distribution --id "${DIST_ID}" \
  --query 'Distribution.ARN' --output text)"
echo "    ${CF_DOMAIN}"

# Bucket policy — only this distribution may GetObject
POLICY="$(python3 - <<PY
import json
print(json.dumps({
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "AllowCloudFrontServicePrincipalRead",
    "Effect": "Allow",
    "Principal": {"Service": "cloudfront.amazonaws.com"},
    "Action": "s3:GetObject",
    "Resource": "arn:aws:s3:::${BUCKET}/*",
    "Condition": {
      "StringEquals": {"AWS:SourceArn": "${DIST_ARN}"}
    }
  }]
}))
PY
)"
aws s3api put-bucket-policy --bucket "${BUCKET}" --policy "${POLICY}"
echo "    bucket policy locked to distribution"

# ---------------------------------------------------------------------------
# Route 53 alias → CloudFront
# ---------------------------------------------------------------------------
echo "==> Route 53 alias ${DOMAIN}"
# CloudFront hosted zone id is global magic: Z2FDTNDATAQYW2
ALIAS_BATCH="$(python3 - <<PY
import json
print(json.dumps({
  "Comment": "Jamzilla → CloudFront",
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "${DOMAIN}",
        "Type": "A",
        "AliasTarget": {
          "HostedZoneId": "Z2FDTNDATAQYW2",
          "DNSName": "${CF_DOMAIN}",
          "EvaluateTargetHealth": False
        }
      }
    },
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "${DOMAIN}",
        "Type": "AAAA",
        "AliasTarget": {
          "HostedZoneId": "Z2FDTNDATAQYW2",
          "DNSName": "${CF_DOMAIN}",
          "EvaluateTargetHealth": False
        }
      }
    }
  ]
}))
PY
)"
aws route53 change-resource-record-sets \
  --hosted-zone-id "${HOSTED_ZONE_ID}" \
  --change-batch "${ALIAS_BATCH}" >/dev/null
echo "    A/AAAA alias → ${CF_DOMAIN}"

# ---------------------------------------------------------------------------
# GitHub OIDC role (immutable sub for post-2026-07-15 repos)
# ---------------------------------------------------------------------------
echo "==> GitHub OIDC role ${ROLE_NAME}"
OIDC_ARN="$(aws iam list-open-id-connect-providers \
  --query "OpenIDConnectProviderList[?contains(Arn, 'token.actions.githubusercontent.com')].Arn | [0]" \
  --output text)"
OWNER_ID="$(gh api "users/${GH_OWNER}" --jq .id)"
REPO_ID="$(gh api "repos/${GH_OWNER}/${GH_REPO}" --jq .id)"
SUB_PATTERN="repo:${GH_OWNER}@${OWNER_ID}/${GH_REPO}@${REPO_ID}:*"
echo "    sub ${SUB_PATTERN}"

TRUST="$(python3 - <<PY
import json
print(json.dumps({
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Federated": "${OIDC_ARN}"},
    "Action": ["sts:AssumeRoleWithWebIdentity", "sts:TagSession"],
    "Condition": {
      "StringEquals": {"token.actions.githubusercontent.com:aud": "sts.amazonaws.com"},
      "StringLike": {"token.actions.githubusercontent.com:sub": "${SUB_PATTERN}"}
    }
  }]
}))
PY
)"

if aws iam get-role --role-name "${ROLE_NAME}" >/dev/null 2>&1; then
  aws iam update-assume-role-policy \
    --role-name "${ROLE_NAME}" \
    --policy-document "${TRUST}" >/dev/null
else
  aws iam create-role \
    --role-name "${ROLE_NAME}" \
    --assume-role-policy-document "${TRUST}" \
    --description "GitHub Actions deploy for ${PROJECT}" \
    --tags Key=Project,Value="${PROJECT}" >/dev/null
fi

DEPLOY_POLICY="$(python3 - <<PY
import json
print(json.dumps({
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "S3Sync",
      "Effect": "Allow",
      "Action": [
        "s3:PutObject", "s3:GetObject", "s3:DeleteObject",
        "s3:ListBucket", "s3:PutObjectAcl"
      ],
      "Resource": [
        "arn:aws:s3:::${BUCKET}",
        "arn:aws:s3:::${BUCKET}/*"
      ]
    },
    {
      "Sid": "CloudFrontInvalidate",
      "Effect": "Allow",
      "Action": [
        "cloudfront:CreateInvalidation",
        "cloudfront:GetInvalidation",
        "cloudfront:GetDistribution"
      ],
      "Resource": "${DIST_ARN}"
    }
  ]
}))
PY
)"
aws iam put-role-policy \
  --role-name "${ROLE_NAME}" \
  --policy-name "${PROJECT}-deploy" \
  --policy-document "${DEPLOY_POLICY}" >/dev/null
ROLE_ARN="$(aws iam get-role --role-name "${ROLE_NAME}" --query Role.Arn --output text)"
echo "    ${ROLE_ARN}"

# ---------------------------------------------------------------------------
# Persist ids for Actions + humans
# ---------------------------------------------------------------------------
mkdir -p "${ROOT}/infra"
cat > "${DEPLOY_ENV}" <<EOF
# Generated by scripts/bootstrap-aws.sh — safe to commit (no secrets).
AWS_REGION=${REGION}
S3_BUCKET=${BUCKET}
CLOUDFRONT_DISTRIBUTION_ID=${DIST_ID}
CLOUDFRONT_DOMAIN=${CF_DOMAIN}
DOMAIN=${DOMAIN}
AWS_ROLE_ARN=${ROLE_ARN}
ACM_CERTIFICATE_ARN=${CERT_ARN}
EOF
echo "==> wrote ${DEPLOY_ENV}"

echo ""
echo "Bootstrap complete."
echo "  Site (once CloudFront is Deployed): https://${DOMAIN}"
echo "  Distribution status may take 5–15 minutes to go Deployed."
echo "  Commit infra/deploy.env and push main to wire CI."
