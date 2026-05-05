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

# Apply the Authentik forward-auth wiring (Middleware + ExternalName +
# /outpost.goauthentik.io/ Ingress). Required for the Authentik login flow.
kubectl apply -f apps/charts/navidrome-values/authentik.yaml
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

## Authentik forward-auth integration

Navidrome has no native OIDC, so Authentik gates the **web UI** via Traefik forward-auth (Authentik's Embedded Outpost), and Navidrome's `ReverseProxyUserHeader` trusts the `X-authentik-username` header the outpost injects. The **Subsonic API** (`/rest/*`, `/share/*`) bypasses Authentik so DSub / play:Sub / Symfonium etc. keep working with Navidrome's native HTTP-basic auth.

### Pieces

| Object | Where | Purpose |
|---|---|---|
| Authentik Proxy Provider + Application | created by `apps/scripts/authentik-oidc-bootstrap.py` | `mode: forward_single`, `external_host: https://music.chifor.dev`, attached to Embedded Outpost |
| `Middleware/authentik-forwardauth` | `apps/charts/navidrome-values/authentik.yaml` (navidrome ns) | Traefik forwardAuth → `authentik-server.authentik.svc.cluster.local/outpost.goauthentik.io/auth/traefik` |
| `Service/authentik-server-ref` | same file (navidrome ns) | ExternalName to authentik-server (lets the navidrome-namespace Ingress target a service in the authentik namespace) |
| `Ingress/navidrome-outpost` | same file (navidrome ns) | Routes `music.chifor.dev/outpost.goauthentik.io/*` to authentik-server-ref so the outpost can set its session cookie on the protected host |
| `Ingress/navidrome-main` | chart (`ingress.main`) | `/` with `traefik.ingress.kubernetes.io/router.middlewares: navidrome-authentik-forwardauth@kubernetescrd` |
| `Ingress/navidrome-subsonic` | chart (`ingress.subsonic`) | `/rest`, `/share` — **NO** middleware, Subsonic clients use Navidrome's native auth |
| `ND_REVERSEPROXYUSERHEADER`, `ND_REVERSEPROXYWHITELIST` | values.yaml `env:` | Navidrome trusts the username header on requests from cluster pod CIDR `10.42.0.0/16` (Traefik runs there) |

### Login flow

1. User visits `https://music.chifor.dev/` → Traefik forward-auth middleware asks the outpost
2. No session yet → outpost responds 302 to `https://music.chifor.dev/outpost.goauthentik.io/start` → which 302s to `https://authentik.chifor.dev/application/o/authorize/?client_id=…`
3. User authenticates at Authentik
4. Authentik 302s back to `https://music.chifor.dev/outpost.goauthentik.io/callback` (handled by `Ingress/navidrome-outpost` → outpost service)
5. Outpost sets `authentik_proxy_*` session cookie on `Domain=chifor.dev`, 302s to `/`
6. Forward-auth re-runs, this time the outpost returns 200 + `X-authentik-username: <user>`
7. Traefik proxies the request to Navidrome with the header
8. Navidrome sees the trusted header, **first user logged in this way becomes admin**, subsequent users get auto-created as regular users

### Adding more proxy-fronted apps

Append to `APPS` in `apps/scripts/authentik-oidc-bootstrap.py` with `provider_type: proxy`, then re-run the script — the new provider will be attached to the Embedded Outpost automatically. The Traefik wiring (Middleware + outpost Ingress + ExternalName) needs to be replicated per app namespace; copy `authentik.yaml` into the new namespace and tweak the host.

### Known limitations

- **No group-based authorization yet** — every authenticated Authentik user can sign into Navidrome. Use Authentik's *Application → Policy bindings* if you need to restrict access (e.g. `group=music`).
- **Subsonic clients still need Navidrome credentials** — Authentik gates the web only. The mobile workflow is: log in via web once (so your account exists), set a Navidrome password under Settings, point your Subsonic client at the same URL with that password.

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
