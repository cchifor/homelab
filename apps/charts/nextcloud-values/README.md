# nextcloud-values

Self-hosted file sync, sharing, calendars, contacts. Replaces OpenCloud (which used MinIO as backend); Nextcloud uses transparent filesystem so Navidrome can read the user's `Music/` subfolder directly via NFS.

| | |
|---|---|
| Chart | `nextcloud/nextcloud` (`helm repo add nextcloud https://nextcloud.github.io/helm/`) |
| Pinned version | `9.0.6` (Nextcloud 33.0.3) |
| Namespace | `nextcloud` |
| Exposure | **Public via Cloudflare Tunnel** at https://cloud.chifor.dev |
| Database | Bundled PostgreSQL (`bitnamilegacy/postgresql:16.4.0-debian-12-r0`) |
| Storage | 5 GiB Longhorn (web root) + 500 GiB advisory NFS (data dir, shared with Navidrome) |
| Cache | None — single-user homelab; re-enable Valkey if you start seeing slow file lock contention |

## Pre-install

NFS server must be reachable on the NAS LXC at `192.168.0.186:/mnt/storage/cloud-data`. See `apps/manifests/shared-nfs/README.md` for one-time setup. The PV/PVC manifests are in that same directory.

```bash
# 1. Apply the shared NFS PVs (binds nextcloud-data + navidrome-music to the same NFS export):
kubectl apply -f apps/manifests/shared-nfs/nextcloud-data.yaml

# 2. Memcache + locking via Valkey (in-namespace, single pod, no auth):
kubectl apply -f apps/charts/nextcloud-values/valkey.yaml

# 3. OPcache tuning ConfigMap (max_accelerated_files=20000,
#    interned_strings_buffer=64; mounted at /usr/local/etc/php/conf.d/):
kubectl apply -f apps/charts/nextcloud-values/opcache-tuning.yaml
```

## Install

```bash
cd ~/work/home/homelab
. apps/charts/nextcloud-values/.secrets.env

helm upgrade --install nextcloud nextcloud/nextcloud \
  --version 9.0.6 \
  -n nextcloud --create-namespace \
  -f apps/charts/nextcloud-values/values.yaml \
  --set "nextcloud.password=$NEXTCLOUD_ADMIN_PASSWORD" \
  --set "externalDatabase.password=$NEXTCLOUD_DB_PASSWORD" \
  --set "postgresql.global.postgresql.auth.password=$NEXTCLOUD_DB_PASSWORD" \
  --timeout 10m
```

First install runs `occ upgrade` + plugin enable; takes ~3 min before `/status.php` returns `installed: true`.

## First login

- URL: https://cloud.chifor.dev
- Username: `chifor`
- Password: `$NEXTCLOUD_ADMIN_PASSWORD` from `.secrets.env` (save in Vaultwarden, then delete the secrets.env line)

Default client folders auto-created in your data tree: `Documents/`, `Music/`, `Photos/`, `Templates/` (plus the Nextcloud manual + intro PDFs). Navidrome reads only the `Music/` subfolder.

## Post-install defaults

```bash
python apps/scripts/nextcloud-defaults.py
```

Idempotent script that handles the things the chart can't:

1. Installs + enables the `user_oidc` app and registers Authentik as a provider (reads client-id / client-secret from the `authentik-oidc` Secret in the nextcloud namespace, set up by `apps/scripts/authentik-oidc-bootstrap.py`).
2. Disables Nextcloud apps unrelated to file management — `activity`, `dashboard`, `photos`, `circles`, `comments`, `recommendations`, `weather_status`, `webhook_listeners`, `nextcloud_announcements`, `survey_client`, `support`, `privacy`, `related_resources`, `contactsinteraction`, `federation`. (`cloud_federation_api`, `federatedfilesharing`, `lookup_server_connector` are Nextcloud-shipped and refuse to disable; benign.)
3. Sets `defaultapp=files` so login lands on the file list, not the generic dashboard.

After this, the Nextcloud login page exposes a "Login with Authentik" button. Authentik users are auto-provisioned in Nextcloud on first sign-in (`mapping-uid: preferred_username` so the Nextcloud username matches your Authentik account).

## Storage layout (shared with Navidrome)

NFS export tree on the NAS LXC:

```
/mnt/storage/cloud-data/        ← exported via NFS, 192.168.0.186
└── data/                        ← Nextcloud datadir (mode 0770, owned 33:33 = www-data)
    ├── .ncdata
    ├── nextcloud.log
    ├── appdata_oc<instid>/      ← Nextcloud internals (cache, previews, etc.)
    └── chifor/                   ← per-user
        └── files/
            ├── Documents/
            ├── Music/             ← ALSO mounted in Navidrome at /music (read-only)
            ├── Photos/
            └── Templates/
```

Permissions:
- Nextcloud writes files mode 0640 owned by uid 33 / gid 33 (www-data)
- Navidrome runs as uid 1000, with **supplementalGroups: [33]** so its process can read group-33 files
- Navidrome's NFS mount uses **subPath `data/chifor/files/Music`** + **`readOnly: true`** → it sees only your Music/ tree, can't write or browse other users' files

## Performance tuning applied

What's wired in `values.yaml` + the side manifests, and why each matters:

| Knob | Default (image) | Set to | Why |
|---|---|---|---|
| `memcache.local` | DB | APCu (in-PHP) | First-tier cache; APCu is process-local, ~ns reads. Set automatically by chart. |
| `memcache.distributed` | DB | Redis (Valkey) | Cache shared across PHP workers — file metadata, JS bundles, share state. |
| `memcache.locking` | **DB** | **Redis (Valkey)** | **Biggest single win** — Nextcloud's transactional file locking goes from 5–20 ms (Postgres) to <1 ms (Valkey). Visible in admin warnings as "Transactional File Locking: The database is used…" until this is set. |
| `opcache.memory_consumption` | 128 MiB | 256 MiB | Holds compiled PHP bytecode. NC has lots of files; default fills up and starts evicting hot code. |
| `opcache.max_accelerated_files` | 10 000 | 20 000 | Same — NC ships ~14 000 PHP files. |
| `opcache.interned_strings_buffer` | 32 MiB | 64 MiB | Deduplicated strings (translation keys, config keys). |
| `memory_limit` | 512 MiB | 1024 MiB | Long-running batch ops (`occ files:scan`, preview generation, `maintenance:repair --include-expensive`) overrun 512 with PHP fatal errors otherwise. |
| `upload_max_filesize` / `post_max_size` | 2/8 MiB | 16 GiB | Allow uploads of full backups, mp4s, raw photo dumps. |

Verified post-tuning via `occ setupchecks`:

```
✓ Transactional File Locking
✓ Memcache: Configured
✓ Mimetype migrations: None
✓ PHP opcache: Correctly configured
```

**The chart's own `redis.config.php` template handles the Valkey wiring** when `REDIS_HOST` is set in the pod's env — that's why `extraEnv` does the work, not a custom config.php fragment. The chart filters `nextcloud.configs:` to a hardcoded list of known keys; arbitrary `cache.config.php` entries get dropped at template render time. (Tried that first — it silently produces no error and no file.)

## Quirks worth knowing

1. **Chart's `nextcloudData.existingClaim` is the supported pattern** for putting the data dir on a separate PVC. Setting `nextcloud.datadir` + `extraVolumeMounts` to the same path causes a "duplicate volumeMount" admission error because the chart auto-mounts at `nextcloud.datadir` from its main PVC.

2. **First-init OOMs at 1 GiB memory limit** — `occ upgrade` peaks ~1.4 GiB. We bumped to 2 GiB. Drop back if you don't run the chart's bundled DB.

3. **Probe windows** — first install does an Apache up + occ upgrade pass that returns 503 on `/status.php` for ~90s. Default chart probes hit `failureThreshold` during that window and kubelet crashloops the pod. Our `livenessProbe.initialDelaySeconds: 180` + `startupProbe.failureThreshold: 30` (5 min budget) handles this; subsequent boots take <30s.

4. **Bundled PostgreSQL uses bitnamilegacy** — same image-archive issue paperless hit in 2025. If `bitnamilegacy/postgresql` ever disappears too, switch to CloudNativePG (already deployed for Immich; cleanest to consolidate eventually).

5. **NFS PV "Released" state after PVC delete** — the PV's `claimRef` retains the deleted PVC's UID. Recreating the PVC won't auto-rebind because the binding controller sees the stale ref. Fix:

   ```bash
   kubectl patch pv nextcloud-data-nfs --type=json -p='[{"op":"remove","path":"/spec/claimRef"}]'
   kubectl apply -f apps/manifests/shared-nfs/nextcloud-data.yaml
   ```

## Uninstall

```bash
helm uninstall nextcloud -n nextcloud
kubectl delete namespace nextcloud   # PVCs deleted (postgres + main web root)
# NFS data on the NAS is RETAINED (PV reclaimPolicy: Retain). To delete:
ssh root@192.168.0.185 'pct exec 101 -- rm -rf /mnt/storage/cloud-data/data'
```

Then clear the stale claimRef on the PV per Quirk #5 if you plan to reinstall.
