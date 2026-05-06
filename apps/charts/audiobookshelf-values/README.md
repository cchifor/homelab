# audiobookshelf-values

[Audiobookshelf](https://www.audiobookshelf.org/) — self-hosted audiobook + podcast server with first-class iOS/Android apps and progress sync across devices.

| | |
|---|---|
| Chart | `bjw-s/app-template` |
| Pinned version | `4.6.2` (chart) / `ghcr.io/advplyr/audiobookshelf:2.30.0` (image) |
| Namespace | `audiobookshelf` |
| Exposure | **Public via Cloudflare Tunnel** at https://audiobooks.chifor.dev |
| Storage | 1 GiB Longhorn (DB) + 5 GiB Longhorn (metadata cache) + NFS for media |

## Install

```bash
# 1. Pre-create NFS dirs (owned by uid 33 / gid 33 = Nextcloud's www-data)
ssh root@192.168.0.185 "pct exec 101 -- sh -c '
  mkdir -p /mnt/storage/cloud-data/data/admin/files/Audiobooks
  mkdir -p /mnt/storage/cloud-data/data/admin/files/Podcasts
  chown -R 33:33 /mnt/storage/cloud-data/data/admin/files/Audiobooks /mnt/storage/cloud-data/data/admin/files/Podcasts
  chmod 0775 /mnt/storage/cloud-data/data/admin/files/Audiobooks /mnt/storage/cloud-data/data/admin/files/Podcasts
'"

# 2. Apply NFS PV/PVC
kubectl apply -f apps/manifests/shared-nfs/nextcloud-data.yaml

# 3. Helm install
helm upgrade --install audiobookshelf bjw-s/app-template \
  --version 4.6.2 \
  -n audiobookshelf --create-namespace \
  -f apps/charts/audiobookshelf-values/values.yaml \
  --timeout 5m
```

## First login

Browse https://audiobooks.chifor.dev — the first launch shows a **"Create Initial User"** screen. Pick a username + password; **that account becomes admin**. There's no chart-baked bootstrap secret.

## Setting up Authentik OIDC (post-install)

The Authentik provider + application + k8s Secret were created automatically by `apps/scripts/authentik-oidc-bootstrap.py`. ABS doesn't read OIDC config from env vars (the chart set them, but ABS persists settings in its SQLite on first init and ignores env afterwards). Configure via the admin UI:

```bash
# Pull the values you'll paste:
kubectl -n audiobookshelf get secret authentik-oidc -o jsonpath='{.data.client-id}' | base64 -d ; echo
kubectl -n audiobookshelf get secret authentik-oidc -o jsonpath='{.data.client-secret}' | base64 -d ; echo
kubectl -n audiobookshelf get secret authentik-oidc -o jsonpath='{.data.issuer-url}' | base64 -d ; echo
```

In the ABS web UI:
1. Top-right user menu → **Settings → Authentication**
2. Toggle **OpenID Connect Authentication**
3. Fill in:

   | Field | Value |
   |---|---|
   | Issuer URL | `https://authentik.chifor.dev/application/o/audiobookshelf/` (from secret) |
   | Authorization URL | `https://authentik.chifor.dev/application/o/authorize/` |
   | Token URL | `https://authentik.chifor.dev/application/o/token/` |
   | Userinfo URL | `https://authentik.chifor.dev/application/o/userinfo/` |
   | JWKS URL | `https://authentik.chifor.dev/application/o/audiobookshelf/jwks/` |
   | Client ID | (from secret) |
   | Client Secret | (from secret) |
   | Auto-launch | ✗ off (you still want a way to log in as the local admin) |
   | Auto-register | ✓ on (auto-creates ABS users for new Authentik logins) |
   | Match existing users by | `Username` |

4. **Save** → the login page now exposes a "Sign in with Authentik" button.

## Adding audiobooks

Drop M4B / MP3 / AAC / FLAC files via Nextcloud at `Audiobooks/<Author>/<Title>/` (any folder structure works; ABS auto-detects from tags). A common layout:

```
/Audiobooks/
├── Brandon Sanderson/
│   ├── The Way of Kings/
│   │   ├── The Way of Kings.m4b
│   │   └── cover.jpg
│   └── Words of Radiance/
│       └── Words of Radiance.m4b
└── ...
```

In ABS UI: Settings → Libraries → Add Library → name "Audiobooks", path `/audiobooks`, type Audiobooks → Save. Same for `/podcasts` if you want the podcast feature.

## Mobile apps

Free, open-source iOS + Android apps on App Store / Play Store. Configuration:
- Server URL: `https://audiobooks.chifor.dev`
- Username + password (same as web)
- (After OIDC is configured: app supports OIDC sign-in too — opens Safari, browser auth flow, returns to app)

Progress syncs across all clients in real time.

## Storage layout

```
/mnt/storage/cloud-data/data/admin/files/
├── Audiobooks/    ← mounted at /audiobooks
└── Podcasts/      ← mounted at /podcasts
```

ABS writes some metadata (cover thumbnails, .ebookCache) into the same folders, hence read-write mount. Doesn't conflict with Nextcloud's view.

## Uninstall

```bash
helm uninstall audiobookshelf -n audiobookshelf
kubectl delete namespace audiobookshelf   # config + metadata PVCs deleted
# Audio files on NFS are RETAINED (PV reclaim policy: Retain)
```
