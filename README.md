# Jamzilla — the website

Public teaser for **Jamzilla** at
[https://jamzilla.dr-data-dude.com](https://jamzilla.dr-data-dude.com).

One static `index.html`. No app server. Photos live inside the HTML as data
URLs so there is nothing else to sync.

---

## How it got this way

We needed a Friday-live plate for WhatsApp feedback — not a FastAPI brain.

| Choice | Why |
|--------|-----|
| Static HTML | The teaser *is* the product for now |
| Private S3 + CloudFront + OAC | 2026 default: bucket stays locked, CDN is the only reader |
| ACM cert in `us-east-1` | CloudFront only accepts certs from that region |
| Route 53 alias | Same account / zone as `dr-data-dude.com` |
| GitHub Actions OIDC | Push to `main` → sync + invalidate. No long-lived AWS keys in GitHub |

This is **not** the interactive-resume App Runner stack. When Jamzilla grows an
API, graduate it. Until then, keep it boring.

---

## Local taste

```bash
open index.html
# or
python3 -m http.server 8080 --directory .
# → http://localhost:8080
```

Edit `index.html`, commit, push. CI does the rest.

---

## Live stack (names)

| Piece | Value |
|-------|-------|
| Domain | `jamzilla.dr-data-dude.com` |
| S3 bucket | see `infra/deploy.env` |
| Region (bucket) | `eu-central-1` |
| ACM | `us-east-1` (CloudFront rule) |
| GitHub OIDC role | `github-actions-jamzilla-the-website` |
| Hosted zone | Route 53 `dr-data-dude.com` |

`infra/deploy.env` is written by bootstrap and read by Actions. Commit it —
nothing secret in there.

---

## One-time bootstrap (human / laptop)

Needs: AWS CLI as `dr-data-dude`, `gh` logged in, Route 53 zone already there.

```bash
# 1) repo on GitHub (if you are recreating from scratch)
gh repo create dr-data-dude/jamzilla-the-website --public --source=. --remote=origin --push

# 2) AWS: bucket, cert, CloudFront, DNS, IAM role
./scripts/bootstrap-aws.sh

# 3) commit deploy.env if bootstrap changed it, then push
git add infra/deploy.env
git commit -m "chore: record CloudFront + bucket ids"
git push origin main
```

Bootstrap is idempotent. Safe to re-run.

---

## Link preview (WhatsApp card)

WhatsApp / iMessage / Slack read **Open Graph** tags in `<head>`:

- `og:title`, `og:description`
- `og:image` → absolute HTTPS URL: `https://jamzilla.dr-data-dude.com/og-image.jpg`

`og-image.jpg` is a 1200×630 crop of the hero session shot. WhatsApp **caches**
previews hard — after you change the image, paste the URL in a **new** chat
thread, or append `?v=2` once to bust cache. Facebook’s debugger also works:
https://developers.facebook.com/tools/debug/

## Everyday ship

```bash
# change the page
$EDITOR index.html
git add index.html
git commit -m "content: freshen teaser"
git push origin main
```

Workflow `.github/workflows/deploy.yml`:

1. Assume `github-actions-jamzilla-the-website` via OIDC  
2. Upload HTML / icons / assets; sync `audio/` only when that tree exists in the runner  
3. Invalidate CloudFront paths `/*`  
4. Smoke `https://jamzilla.dr-data-dude.com` (pretty `/listen/` + `/lineup/`, and ready `/audio/*.mp3` as `audio/mpeg`)

Manual re-run: Actions → Deploy → Run workflow.

### Session tapes (`audio/`)

MP3 cuts are **gitignored** (large binaries). CI will not invent them. After cutting new tracks locally:

```bash
./scripts/sync-audio.sh
```

That uploads with `Content-Type: audio/mpeg` and invalidates `/audio/*`. Without the objects in S3, CloudFront’s custom 403/404→`index.html` response makes players fetch homepage HTML instead of sound.

---

## Manual deploy (break-glass)

```bash
set -a && source infra/deploy.env && set +a
aws s3 sync . "s3://${S3_BUCKET}/" \
  --exclude '.git/*' --exclude '.github/*' --exclude 'scripts/*' \
  --exclude 'infra/*' --exclude 'README.md' --exclude '.gitignore' \
  --exclude '*.md' --exclude 'audio/*'
./scripts/sync-audio.sh   # when local cuts exist
aws cloudfront create-invalidation \
  --distribution-id "${CLOUDFRONT_DISTRIBUTION_ID}" \
  --paths '/*'
curl -I "https://${DOMAIN}"
```

---

## Future us — step two ideas (not built)

- Split photos out of the HTML into `/assets/` (smaller git, better cache)
- WhatsApp / poll / RSVP page
- Self-host fonts if we want zero third-party calls
- Only then: FastAPI + App Runner via `ai-ship-stack`

---

## Hard never

- Public S3 bucket ACLs  
- Long-lived AWS access keys in GitHub secrets  
- Touching `resume.dr-data-dude.com`  
- Claiming “live” without a green smoke on the public URL
