# gitea-values

Self-hosted git hosting (issues, PRs, packages, registry, actions).

| | |
|---|---|
| Chart | `gitea-charts/gitea` (`helm repo add gitea-charts https://dl.gitea.com/charts/`) |
| Pinned version | `12.5.3` (gitea 1.25.5) |
| Namespace | `gitea` |
| Exposure | **HTTP public via Cloudflare Tunnel** (SSH stays cluster-internal) |
| URL | https://gitea.chifor.dev |
| Storage | 20 GiB Longhorn (gitea data) + 10 GiB Longhorn (PostgreSQL) |

## Install

```bash
cd ~/work/home/homelab
. apps/charts/gitea-values/.secrets.env

helm upgrade --install gitea gitea-charts/gitea \
  --version 12.5.3 \
  -n gitea --create-namespace \
  -f apps/charts/gitea-values/values.yaml \
  --set "gitea.admin.password=$GITEA_ADMIN_PASSWORD" \
  --set "postgresql.global.postgresql.auth.password=$GITEA_DB_PASSWORD" \
  --timeout 10m
```

## First login

- URL: https://gitea.chifor.dev
- Username: `cchifor`
- Password: `$GITEA_ADMIN_PASSWORD` from `.secrets.env`
- Email: `chifor@gmail.com`

Change the admin password via the user settings UI after first login.

## SSH access (cluster-internal only)

Cloudflare Tunnel public hostnames don't support raw TCP for git-over-SSH cleanly. SSH is reachable inside the cluster only:

```bash
# port-forward gitea SSH locally
kubectl -n gitea port-forward svc/gitea-ssh 2222:22

# clone via local port-forward
git clone ssh://git@localhost:2222/cchifor/<repo>.git
```

For HTTPS-based git operations, use the public URL — works from anywhere:

```bash
git clone https://gitea.chifor.dev/cchifor/<repo>.git
```

## Quirk: chart's `gitea-http` Service is headless by default

The chart sets `service.http.clusterIP: None` by default (intended for HA setups), which the cloudflare-tunnel-ingress-controller refuses to route to. Our values override with `service.http.clusterIP: ""` to get a real ClusterIP. If the operator log shows `service gitea/gitea-http has None for cluster ip, headless service is not supported`, this override is missing or got reverted.

## Authentik OIDC integration (manual, optional)

Gitea natively supports OAuth2/OIDC providers via the UI:

1. In **Authentik** admin (https://authentik.chifor.dev/if/admin/):
   - Create an **OAuth2/OpenID Provider** with:
     - Authorization flow: implicit consent (or default)
     - Client type: Confidential
     - Redirect URIs: `https://gitea.chifor.dev/user/oauth2/Authentik/callback`
   - Note the `client_id` and `client_secret`
   - Create an **Application** linked to that provider, slug `gitea`
2. In **Gitea** admin (Site Administration → Authentication Sources):
   - Add OAuth2 source:
     - Authentication Name: `Authentik`
     - OAuth2 Provider: `OpenID Connect`
     - Client ID + Client Secret from above
     - OpenID Connect Auto Discovery URL: `https://authentik.chifor.dev/application/o/gitea/.well-known/openid-configuration`
3. Login flow: now Gitea's login page shows a "Sign in with Authentik" button.

## Uninstall

```bash
helm uninstall gitea -n gitea
kubectl delete namespace gitea         # PVCs deleted (postgres + gitea data)
# Manually delete CF DNS CNAME for gitea.chifor.dev (operator orphans it).
```
