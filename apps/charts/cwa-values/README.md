# cwa-values

[Calibre-Web Automated](https://github.com/crocodilestick/Calibre-Web-Automated) — modern fork of Calibre-Web that auto-ingests EPUB/PDF/MOBI/AZW3 dropped into a folder, fetches metadata, converts formats, and serves a browser reader + OPDS feed.

| | |
|---|---|
| Chart | `bjw-s/app-template` |
| Pinned version | `4.6.2` (chart) / `crocodilestick/calibre-web-automated:V3.1.4` (image) |
| Namespace | `cwa` |
| Exposure | **Public via Cloudflare Tunnel** at https://books.chifor.dev |
| Storage | 1 GiB Longhorn (config DB) + NFS subPaths for the Calibre library + ingest folder |

## Pre-install

```bash
# Pre-create the NFS subdirectories owned by uid 33 / gid 33 (Nextcloud's www-data)
ssh root@192.168.0.185 "pct exec 101 -- sh -c '
  mkdir -p /mnt/storage/cloud-data/data/admin/files/Books/Library
  mkdir -p /mnt/storage/cloud-data/data/admin/files/Books/_ingest
  chown -R 33:33 /mnt/storage/cloud-data/data/admin/files/Books
  chmod 0775 /mnt/storage/cloud-data/data/admin/files/Books
'"

# Apply the NFS PV/PVC for cwa-books
kubectl apply -f apps/manifests/shared-nfs/nextcloud-data.yaml
```

## Install

```bash
helm upgrade --install cwa bjw-s/app-template \
  --version 4.6.2 \
  -n cwa --create-namespace \
  -f apps/charts/cwa-values/values.yaml \
  --timeout 5m
```

First boot installs Calibre 8.8 inside the container (~1 min) before the web UI is reachable. Watch:

```bash
kubectl -n cwa logs deploy/cwa -f
# look for: "Calibre setup completed successfully"
```

## First login + post-install password

- URL: https://books.chifor.dev
- Username: `admin`
- Default password: `admin123` (rotate immediately)

**Don't use the admin user-list "Edit User" form to rotate** — until at least v4.0.6 it had a bug where saves silently no-op'd while reporting success. Use one of:

```bash
# Generate a random password + apply (printed at end):
python apps/scripts/cwa-defaults.py

# Or set a stable known password (idempotent re-runs):
CWA_ADMIN_PASSWORD='your-pass' python apps/scripts/cwa-defaults.py
```

The script hashes via the pod's own Werkzeug (so format always matches the running CWA), parameterized-UPDATEs `app.db`, then verifies via the public web flow (CSRF-aware POST `/login` → authenticated `/me` probe).

Three idempotent branches:
1. supplied password already works on the web flow → no-op skip
2. password drifted (or fresh install / migration corruption) → reset hash + verify
3. admin user missing entirely → bail with a clear error (CWA's first-launch normally creates it; this only happens if `/config` is mid-init or wiped)

The /me Personal-page form for changing your own password works correctly even on V3.1.4 — only the admin user-list edit form was broken.

## Adding books

Two paths:

### A) Drag-and-drop via Nextcloud (the point of this whole setup)

1. Sign in to https://cloud.chifor.dev
2. Navigate to `Books/_ingest/`
3. Drop EPUBs/PDFs/MOBIs into that folder
4. CWA detects the file within ~30 s, fetches metadata from Google Books / OpenLibrary, optionally converts to EPUB, and files the final copy under `Books/Library/<Author>/<Title>/`
5. The book appears in CWA's library view (sometimes needs a refresh)

### B) Direct upload via the CWA UI

Top-right "Upload" button → choose file. Skips the auto-ingest pipeline.

## Sending to Kindle / Kobo

Settings → email → configure SMTP credentials. Then any book has a "Send to..." button that emails it to your `@kindle.com` / Kobo address as an attachment. Most Kindles allow up to 50 MB attachments after Amazon-side conversion.

## Authentik integration (deferred)

CWA inherits Calibre-Web's Flask-Login auth. There's no native OIDC. Options if you want SSO:

1. **Authentik forward-auth via Traefik** (same Middleware pattern as Navidrome) -- gates the entire web UI but breaks OPDS clients that send HTTP-basic. Practical compromise: gate `/` but exempt `/opds*` from the middleware.
2. **Reverse-proxy header trust** -- CWA has a `proxyAuth` setting in its admin panel that trusts a configured header (e.g. `X-authentik-username`). Set it, then add the same Authentik forward-auth Middleware -- single sign-on, no OPDS break since CWA still does its own user lookup by header.

Both deferred for v1. Local CWA accounts work fine for single user / family use.

## Ingest tuning

CWA polls the `_ingest` folder every 30 s. Settings → Library → "Auto-Convert" controls the target format (default: EPUB). "Keep originals" leaves both old + new format under the library; off = original deleted after conversion. For maximum compatibility I set:

- target = EPUB
- keep originals = ON (so PDFs and MOBIs stay alongside the EPUBs for cross-device reading)

## Storage layout in NFS

```
/mnt/storage/cloud-data/data/admin/files/Books/
├── _ingest/          ← drop new books here (CWA monitors)
└── Library/          ← CWA's organized output, matches Calibre's tree
    ├── metadata.db   ← Calibre's SQLite -- DON'T move/rename
    └── <Author>/<Title>/<Title>.epub
```

The `Library/` tree is what Calibre Desktop reads if you ever run that locally pointed at the same NFS share.

## Uninstall

```bash
helm uninstall cwa -n cwa
kubectl delete namespace cwa     # config PVC deleted (Longhorn)
# Books on NFS are RETAINED -- the NFS PV reclaim policy is Retain
```
