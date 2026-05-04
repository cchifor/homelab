# uptime-kuma-values

Status / uptime monitoring for the apps you care about.

| | |
|---|---|
| Chart | `dirsigler/uptime-kuma` (`helm repo add dirsigler https://dirsigler.github.io/uptime-kuma-helm`) |
| Pinned version | `4.1.0` (uptime-kuma 2.3.0) |
| Namespace | `uptime-kuma` |
| Exposure | **LAN-only** via Traefik + LE cert |
| URL | https://uptime.chifor.dev |
| Storage | 1 GiB Longhorn |

## Install

```bash
helm upgrade --install uptime-kuma dirsigler/uptime-kuma \
  --version 4.1.0 \
  -n uptime-kuma --create-namespace \
  -f apps/charts/uptime-kuma-values/values.yaml \
  --timeout 5m
```

## First setup

1. Browse https://uptime.chifor.dev — you'll be prompted to create the admin account on first launch (no default credentials).
2. After creation, add monitors via the UI:
   - **HTTP(s)** → check URL (most apps)
   - **TCP Port** → check raw service
   - **Push** → external services ping uptime-kuma when alive
3. Configure notification channels in **Settings → Notifications** (email, webhook, ntfy, etc.)

Useful starter monitors for this homelab:

| Name | Type | URL/target |
|---|---|---|
| Authentik | HTTPS | https://authentik.chifor.dev/-/health/ready/ |
| Vaultwarden | HTTPS | https://vaultwarden.chifor.dev/alive |
| Gitea | HTTPS | https://gitea.chifor.dev/api/healthz |
| Grafana | HTTPS | https://grafana.chifor.dev/api/health |
| Homepage | HTTPS | https://home.chifor.dev/ |
| Rancher | HTTPS | https://rancher.lan/ping |
| MinIO | HTTPS | http://192.168.0.186:9000/minio/health/live |

## Uninstall

```bash
helm uninstall uptime-kuma -n uptime-kuma
kubectl delete namespace uptime-kuma   # PVC also deleted
```
