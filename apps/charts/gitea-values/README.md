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

## Authentik OIDC integration

The Authentik provider + application + k8s Secret were created automatically by `apps/scripts/authentik-oidc-bootstrap.py`. The Authentik-side work is **already done**. What remains is one Gitea-side step (the chart can't add an authentication source via values; Gitea requires this via CLI or web UI):

```bash
# Pull the OIDC client_id and client_secret from the bootstrap-created Secret
CLIENT_ID=$(kubectl -n gitea get secret authentik-oidc -o jsonpath='{.data.client-id}' | base64 -d)
CLIENT_SECRET=$(kubectl -n gitea get secret authentik-oidc -o jsonpath='{.data.client-secret}' | base64 -d)

# Run gitea admin CLI inside the running pod to add the OAuth2 source.
# IMPORTANT: --name MUST be "Authentik" (capital A) — Gitea's callback URL
# is /user/oauth2/<name>/callback (case-sensitive), and the bootstrap script
# registered the redirect_uri with capital A. Renaming the source here
# breaks the round-trip with Authentik (HTTP 400, redirect_uri mismatch).
kubectl -n gitea exec -it $(kubectl -n gitea get pod -l app.kubernetes.io/name=gitea -o name | head -1) -- gitea admin auth add-oauth \
  --name "Authentik" \
  --provider openidConnect \
  --key "$CLIENT_ID" \
  --secret "$CLIENT_SECRET" \
  --auto-discover-url "https://authentik.chifor.dev/application/o/gitea/.well-known/openid-configuration" \
  --scopes "openid,profile,email" \
  --skip-local-2fa
```

After this, Gitea's login page shows a "Sign in with Authentik" button next to the username/password form. Existing Gitea users can link their account by signing in via Authentik once. New users (those who don't exist in Gitea yet) get auto-created on first OIDC sign-in.

To remove or re-add the auth source later:

```bash
kubectl -n gitea exec -it ... -- gitea admin auth list                      # find the ID
kubectl -n gitea exec -it ... -- gitea admin auth delete --id <ID>         # remove
```

## Uninstall

```bash
helm uninstall gitea -n gitea
kubectl delete namespace gitea         # PVCs deleted (postgres + gitea data)
# Manually delete CF DNS CNAME for gitea.chifor.dev (operator orphans it).
```
