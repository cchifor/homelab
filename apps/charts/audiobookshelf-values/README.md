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

## Post-install defaults (one command — replaces the manual UI dance)

```bash
python apps/scripts/audiobookshelf-defaults.py
```

Idempotent script. Three branches:

1. **Fresh install** (`status.isInit == false`): creates the initial admin user (default `admin` / random 24-char password printed at end), then PATCHes `/api/auth-settings` with all OIDC fields read from the `authentik-oidc` Secret in the namespace. After this, the login page exposes "Sign in with Authentik" and `/status` reports `authMethods: ["local", "openid"]`.
2. **Already initialized + `AUDIOBOOKSHELF_ADMIN_PASSWORD` env supplied + correct**: logs in, reconciles OIDC fields if drifted.
3. **Already initialized + password unknown/wrong**: bails with a clear error. Either set the env var, or wipe `/config` to start fresh.

Override the admin user/password via env:

```bash
AUDIOBOOKSHELF_ADMIN_USER='c4' \
AUDIOBOOKSHELF_ADMIN_PASSWORD='your-pass' \
  python apps/scripts/audiobookshelf-defaults.py
```

### Recovery: don't even need the local admin password

With OIDC's `Match existing users by: username` + `Auto-register: true`, your **Authentik `admin` account auto-links to ABS's local `admin`** on first OIDC login. You can use ABS forever via Authentik without ever knowing the local password — the password drift problem doesn't actually bite.

If you DO want the local password (e.g. for the iOS app's local login flow), the script saves a recovery copy to `$TEMP/audiobookshelf-admin-pass.txt` before the API call, in case a downstream print crashes.

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
