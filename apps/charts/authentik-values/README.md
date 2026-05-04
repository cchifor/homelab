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

### Future: switch Redis subchart to standalone Valkey

For consistency with paperless-ngx (which already runs standalone Valkey), the Authentik Redis subchart can be replaced with a standalone Valkey deployment. **Not currently necessary** — Authentik's chart is using upstream `docker.io/library/redis` images that work fine. Migration plan when you decide to do it:

```bash
# 1. Apply a standalone Valkey (mirror of paperless-ngx-values/valkey.yaml,
#    with namespace authentik and service name authentik-valkey)
# 2. helm upgrade authentik with redis.enabled=false and an env override:
#    AUTHENTIK_REDIS__HOST=authentik-valkey.authentik.svc.cluster.local
# 3. Delete the old redis StatefulSet and its PVC
```

Same pattern applies to Nextcloud's Redis subchart. Sessions are short-lived so the data loss is just brief login-state churn.

## Authentik OIDC integration with downstream apps

Authentik issues OIDC providers + applications for downstream apps via the bootstrap script `apps/scripts/authentik-oidc-bootstrap.py`. Run once after install:

```bash
. apps/charts/authentik-values/.secrets.env
PYTHONIOENCODING=utf-8 python apps/scripts/authentik-oidc-bootstrap.py
```

This creates Authentik OAuth2 providers + Applications for Grafana, ArgoCD, Gitea, Vaultwarden, and writes a Secret `authentik-oidc` to each app's namespace with `client-id`, `client-secret`, `issuer-url` keys.

Per-app activation steps (Grafana + ArgoCD are wired; Gitea + Vaultwarden need one extra step) are documented in:

- `apps/charts/kube-prometheus-stack-values/values.yaml` — Grafana (already active via grafana.ini.auth.generic_oauth)
- `apps/charts/argocd-values/values.yaml` — ArgoCD (already active via configs.cm.oidc.config)
- `apps/charts/gitea-values/README.md` — Gitea (run `gitea admin auth add-oauth` post-install)
- `apps/charts/vaultwarden-values/README.md` — Vaultwarden (extra `SSO_ENABLED` env vars; opt-in)

Authentik admin: https://authentik.chifor.dev/if/admin/ — managed Applications appear under Applications → Applications.

## Notes

- `.secrets.env` is gitignored via `**/.secrets.env` in repo root `.gitignore`.
- Secret rotation: regenerate the entries in `.secrets.env`, re-run the install command. Re-running with new `AUTHENTIK_BOOTSTRAP_*` values does NOT change the existing admin user — that's only set on first install.
- The `authentik.postgresql.password` AND `postgresql.auth.password` MUST match (chart consumer-side env var + chart subchart's own password). Setting only one results in `fe_sendauth: no password supplied` connection errors from the worker pod.
