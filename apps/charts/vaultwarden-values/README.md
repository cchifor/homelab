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

Master password is set on account creation in step 2 above.

## Authentik OIDC (experimental — opt in if you want)

Vaultwarden 1.30+ has experimental OIDC support that does work for the homelab use case. The Authentik provider + k8s Secret were created automatically by `apps/scripts/authentik-oidc-bootstrap.py`. To enable on the Vaultwarden side, helm-upgrade with these extra values (and the existing chart values):

```bash
. apps/charts/vaultwarden-values/.secrets.env
helm upgrade vaultwarden guerzon/vaultwarden \
  --version 0.36.4 \
  -n vaultwarden \
  -f apps/charts/vaultwarden-values/values.yaml \
  --set adminToken.value="$VAULTWARDEN_ADMIN_TOKEN" \
  --set 'extraEnvVars[0].name=SSO_ENABLED' \
  --set 'extraEnvVars[0].value="true"' \
  --set 'extraEnvVars[1].name=SSO_AUTHORITY' \
  --set 'extraEnvVars[1].value=https://authentik.chifor.dev/application/o/vaultwarden/' \
  --set-file 'extraEnvVars[2].value=<(kubectl -n vaultwarden get secret authentik-oidc -o jsonpath="{.data.client-id}" | base64 -d)' \
  --set 'extraEnvVars[2].name=SSO_CLIENT_ID' \
  --set-file 'extraEnvVars[3].value=<(kubectl -n vaultwarden get secret authentik-oidc -o jsonpath="{.data.client-secret}" | base64 -d)' \
  --set 'extraEnvVars[3].name=SSO_CLIENT_SECRET'
```

Vaultwarden's SSO flow is still rough — supports auth but not auto-account-creation; users must already exist in Vaultwarden by email. Recommend keeping master-password auth as the default until Vaultwarden's SSO matures further.

## Uninstall

```bash
helm uninstall vaultwarden -n vaultwarden
kubectl delete namespace vaultwarden       # PVC also deleted
# Manually delete CF DNS CNAME (operator orphans it):
#   curl -X DELETE "https://api.cloudflare.com/client/v4/zones/<ZONE_ID>/dns_records/<REC_ID>"
```
