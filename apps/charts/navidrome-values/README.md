# navidrome-values

[Navidrome](https://github.com/navidrome/navidrome) — self-hosted Subsonic-compatible music server with a modern web UI. Streams to any Subsonic client (DSub, play:Sub, Symfonium, Substreamer, Sonixd, …).

| | |
|---|---|
| Chart | `bjw-s/app-template` (`helm repo add bjw-s https://bjw-s-labs.github.io/helm-charts`) |
| Pinned version | `4.6.2` (chart) / `ghcr.io/navidrome/navidrome:0.57.0` (image) |
| Namespace | `navidrome` |
| Exposure | **LAN-only** via Traefik + LE cert |
| URL | https://music.chifor.dev |
| Storage | 1 GiB Longhorn (DB+cache) + 50 GiB Longhorn (music library, RWO) |

## Install

```bash
helm upgrade --install navidrome bjw-s/app-template \
  --version 4.6.2 \
  -n navidrome --create-namespace \
  -f apps/charts/navidrome-values/values.yaml \
  --timeout 5m
```

## First login

Browse https://music.chifor.dev — Navidrome shows a **"Create Admin"** screen on first launch. Pick a username + password; that account becomes the cluster admin. There is no chart-baked bootstrap secret.

## Adding music

The `/music` PVC is empty on first install. To copy your collection in:

```bash
# One-shot copy from the operator machine
POD=$(kubectl -n navidrome get pod -l app.kubernetes.io/name=navidrome -o name | head -1)
kubectl -n navidrome cp ./Music/ $POD:/music/

# Trigger a re-scan (or wait for the periodic ND_SCANSCHEDULE)
kubectl -n navidrome exec $POD -- wget -qO- --post-data= http://127.0.0.1:4533/api/scanner/scan
```

Or if you have a NAS, swap the `music` persistence entry for an NFS/CIFS-backed volume:

```yaml
persistence:
  music:
    enabled: true
    type: nfs
    server: 192.168.0.186
    path: /mnt/storage/music
    advancedMounts:
      main:
        main:
          - path: /music
            readOnly: true   # safer if other apps also write there
```

(You'd need an NFS export on the NAS LXC; MinIO doesn't speak NFS, so this needs additional setup. Keeping the default Longhorn PVC is the simplest path.)

## Subsonic clients

Navidrome speaks the Subsonic API on the **same port** as the web UI (4533). Point any Subsonic client at:

| Field | Value |
|---|---|
| Server URL | `https://music.chifor.dev` |
| Username | (the admin user you created) |
| Password | (the admin password) |

Most modern clients support OpenSubsonic extensions (lyrics, ratings, podcasts) which Navidrome implements.

## Authentik OIDC integration (deferred)

Navidrome has **no native OIDC support**. Subsonic clients use HTTP-basic / token auth, and the web UI uses Navidrome's own session cookies. To put Authentik in front of the web UI, you'd need an Authentik Outpost running in proxy/forward-auth mode in front of the Ingress — the Subsonic API would need to be either exempted from the proxy or fronted with a separate route. Non-trivial; deferred.

## Quirks

- **Navidrome image runs as uid 1000.** The `defaultPodOptions.securityContext` block sets `fsGroup: 1000` so the kubelet `chgrp`s the Longhorn PVCs at mount time; without this, Navidrome's DB init fails with EACCES on first launch.
- **RWO PVCs + replicas: 1** — `strategy: Recreate` ensures the volume detaches from the old pod before the new one comes up. With `RollingUpdate` (default), the new pod can't attach the volume and the deploy hangs.
- **Music PVC growth** — Longhorn lets you expand by editing the PVC's `spec.resources.requests.storage`. The pod has to restart for the new size to be visible inside the container.
- **Subsonic legacy auth** (`ND_ENABLELEGACYSUBSONICAUTH=true`) uses unsalted MD5 to hash the password in the URL. Fine on a LAN with TLS; turn it off if you ever expose the server publicly.

## Uninstall

```bash
helm uninstall navidrome -n navidrome
kubectl delete namespace navidrome      # PVCs deleted (DB + music library)
```

To preserve the music library across a reinstall, delete the helm release **without** deleting the namespace, and reinstall — Longhorn re-binds the PV by name.
