# authentik-values

Upstream-chart-with-our-values pattern for [authentik](https://goauthentik.io/) — the Identity Provider that gates SSO for downstream apps.

| | |
|---|---|
| Chart | `authentik/authentik` (added via `helm repo add authentik https://charts.goauthentik.io`) |
| Pinned version | `2026.2.2` |
| Namespace | `authentik` |
| Exposure | **Public via Cloudflare Tunnel** (so OIDC redirects from public apps complete cleanly without leaving CF) |
| URL | https://authentik.chifor.dev |

## First install

Secrets are pre-generated into `.secrets.env` (gitignored). Don't commit them.

```bash
cd ~/work/home/homelab
. apps/charts/authentik-values/.secrets.env

helm upgrade --install authentik authentik/authentik \
  --version 2026.2.2 \
  -n authentik --create-namespace \
  -f apps/charts/authentik-values/values.yaml \
  --set authentik.secret_key="$AUTHENTIK_SECRET_KEY" \
  --set authentik.postgresql.password="$AUTHENTIK_POSTGRES_PASSWORD" \
  --set postgresql.auth.password="$AUTHENTIK_POSTGRES_PASSWORD" \
  --set 'global.env[0].name=AUTHENTIK_BOOTSTRAP_PASSWORD' \
  --set "global.env[0].value=$AUTHENTIK_ADMIN_PASSWORD" \
  --set 'global.env[1].name=AUTHENTIK_BOOTSTRAP_TOKEN' \
  --set "global.env[1].value=$AUTHENTIK_ADMIN_TOKEN" \
  --set 'global.env[2].name=AUTHENTIK_BOOTSTRAP_EMAIL' \
  --set 'global.env[2].value=admin@chifor.dev' \
  --timeout 10m
```

The `cloudflare-tunnel-ingress-controller` operator picks up the Ingress, auto-creates the public hostname route + DNS CNAME, and `https://authentik.chifor.dev` is reachable within ~30 seconds.

## First-login credentials

Bootstrap user (configured by the install above):

- Email: `admin@chifor.dev`
- Password: `$AUTHENTIK_ADMIN_PASSWORD` from `.secrets.env`

**Change the password after first login.** The `.secrets.env` admin password is only the bootstrap value — once you set a new one in the UI, the env var becomes stale.

## Upgrade

Same command as install (helm `upgrade --install` is idempotent). Bump `--version` for new chart releases.

## Uninstall

```bash
helm uninstall authentik -n authentik
kubectl delete namespace authentik   # cleans up PVC and any leftover resources
# Also delete the orphaned DNS CNAME in Cloudflare (operator doesn't auto-clean):
#   curl -X DELETE -H "Authorization: Bearer $TF_VAR_cloudflare_api_token" \
#     "https://api.cloudflare.com/client/v4/zones/<ZONE_ID>/dns_records/<RECORD_ID>"
```

## Subcharts

The chart bundles upstream PostgreSQL + Redis (no longer Bitnami images as of authentik 2025+, so the August 2025 Bitnami breakage doesn't affect us). Both run as StatefulSets in the `authentik` namespace.

## Notes

- `.secrets.env` is gitignored via `**/.secrets.env` in repo root `.gitignore`.
- Secret rotation: regenerate the entries in `.secrets.env`, re-run the install command. Re-running with new `AUTHENTIK_BOOTSTRAP_*` values does NOT change the existing admin user — that's only set on first install.
- The `authentik.postgresql.password` AND `postgresql.auth.password` MUST match (chart consumer-side env var + chart subchart's own password). Setting only one results in `fe_sendauth: no password supplied` connection errors from the worker pod.
