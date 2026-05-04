# vaultwarden-values

Self-hosted Bitwarden-compatible password manager.

| | |
|---|---|
| Chart | `guerzon/vaultwarden` (`helm repo add guerzon https://guerzon.github.io/vaultwarden`) |
| Pinned version | `0.36.4` (vaultwarden 1.36.0) |
| Namespace | `vaultwarden` |
| Exposure | **Public via Cloudflare Tunnel** (`ingress.class: cloudflare-tunnel`) |
| URL | https://vaultwarden.chifor.dev |
| Storage | 5 GiB Longhorn PVC, SQLite database |

## Install

```bash
cd ~/work/home/homelab
. apps/charts/vaultwarden-values/.secrets.env

helm upgrade --install vaultwarden guerzon/vaultwarden \
  --version 0.36.4 \
  -n vaultwarden --create-namespace \
  -f apps/charts/vaultwarden-values/values.yaml \
  --set adminToken.value="$VAULTWARDEN_ADMIN_TOKEN" \
  --timeout 5m
```

## First use

1. Browse https://vaultwarden.chifor.dev
2. Create an account (signups currently allowed by `signupsAllowed: true`)
3. Once you have your account, **lock down further signups**:
   ```bash
   helm upgrade vaultwarden guerzon/vaultwarden -n vaultwarden \
     -f apps/charts/vaultwarden-values/values.yaml \
     --reuse-values --set signupsAllowed=false
   ```
4. Admin panel at https://vaultwarden.chifor.dev/admin (use `$VAULTWARDEN_ADMIN_TOKEN` from `.secrets.env`)

## Bitwarden client setup

Set self-host server URL to `https://vaultwarden.chifor.dev` in:
- Browser extensions: Settings → Self-hosted environment → Server URL
- Mobile apps: Login screen → Self-hosted → Server URL
- Desktop app: same pattern

Master password is set on account creation in step 2 above. Vaultwarden does NOT use Authentik for SSO at this time (vaultwarden's experimental OIDC support isn't reliable enough yet).

## Uninstall

```bash
helm uninstall vaultwarden -n vaultwarden
kubectl delete namespace vaultwarden       # PVC also deleted
# Manually delete CF DNS CNAME (operator orphans it):
#   curl -X DELETE "https://api.cloudflare.com/client/v4/zones/<ZONE_ID>/dns_records/<REC_ID>"
```
