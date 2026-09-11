# Jamzilla — the website (teaser sources)

Public teaser HTML/assets for **Jamzilla**.

## Live origin (2026-09-12)

The **live site** is no longer CloudFront/S3.

```
https://jamzilla.dr-data-dude.com
  → EC2 nginx (TLS)
  → SSH reverse tunnel :18791
  → Mini jamzilla-band :8791
```

This repo is the **content source** for the teaser tree. Sync into the band
app with:

```bash
# from jamzilla-band
bash scripts/mini/sync-teaser.sh
```

Or keep a copy under `jamzilla-band/teaser/`.

## Retired door

S3 + CloudFront (`E26XGGZ4NR0X8Z`) used to be the public origin (Aug 20 → Sep 12).
DNS now points at the edge EIP. The GitHub Actions S3 deploy is **paused** so
we do not accidentally republish a second site.

## Local taste

```bash
open index.html
# or develop against the band one-port:
# ../jamzilla-band on :8791 with TEASER_DIR pointing here
```

## Hard never

- Claiming CloudFront is “live” after Option A
- Public S3 bucket ACLs
- Touching `resume.dr-data-dude.com`
