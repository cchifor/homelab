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

## First setup (manual, can't automate — admin user creation is web-only)

Uptime Kuma has no API key bootstrap; the admin account is created via the web wizard on first launch and cannot be set via env var or config file. Steps:

1. Browse **https://uptime.chifor.dev** — you'll see the "Create your admin account" wizard.
2. Set username + password. **Save these in Vaultwarden.**
3. After login, add monitors via the UI (next section).
4. Configure notification channels in **Settings → Notifications** (email, webhook, ntfy, etc.) — pick at least one so alerts actually reach you.

**Once admin is created**, the Uptime Kuma API can be scripted via the `uptime-kuma-api` Python package (`pip install uptime-kuma-api`). A starter automation script could batch-add the monitors below, but the initial admin must be created manually first.

## DNS for LAN-only hostnames

`rancher.lan` is LAN-only (no public DNS) — your operator machine resolves it via `/etc/hosts`, but pods inside the cluster see only CoreDNS. To make `rancher.lan` resolvable from any pod, the cluster has a custom CoreDNS ConfigMap at `apps/manifests/coredns-custom/configmap.yaml` adding the rancher.lan zone. Without it, Uptime Kuma's monitor on `https://rancher.lan/ping` returns `ENOTFOUND`. Apply with:

```bash
kubectl apply -f apps/manifests/coredns-custom/configmap.yaml
kubectl -n kube-system rollout restart deploy/coredns
```

To extend for any other LAN-only hostnames you set up later, edit the ConfigMap to add another zone block and re-apply.

## Add the homelab's monitors

Useful starter monitors for this homelab:

| Name | Type | URL/target |
|---|---|---|
| Authentik | HTTPS | https://authentik.chifor.dev/-/health/ready/ |
| Vaultwarden | HTTPS | https://vaultwarden.chifor.dev/alive |
| Gitea | HTTPS | https://gitea.chifor.dev/api/healthz |
| Grafana | HTTPS | https://grafana.chifor.dev/api/health |
| Homepage | HTTPS | https://home.chifor.dev/ |
| Rancher | HTTPS | https://rancher.lan/ping (toggle **"Ignore TLS/SSL error"** ON in the monitor — Rancher serves a `dynamiclistener-ca` self-signed cert, not LE) |
| MinIO | HTTPS | http://192.168.0.186:9000/minio/health/live |

## Uninstall

```bash
helm uninstall uptime-kuma -n uptime-kuma
kubectl delete namespace uptime-kuma   # PVC also deleted
```
