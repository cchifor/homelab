# paperless-ngx-values

OCR + searchable document archive. Drop PDFs / scans into the consume folder, paperless OCRs them, tags them, indexes the text, and serves a searchable web UI.

| | |
|---|---|
| Chart | `gabe565/paperless-ngx` (`helm repo add gabe565 https://charts.gabe565.com`) |
| Pinned version | `0.24.1` (paperless-ngx 2.14.7) |
| Namespace | `paperless` |
| Exposure | **Public via Cloudflare Tunnel** (forced via legacy `kubernetes.io/ingress.class` annotation) |
| URL | https://paperless.chifor.dev |
| Storage | 30 GiB Longhorn (media), 5 GiB each (data, consume, export), 5 GiB Longhorn (postgres) |

## Pre-install: standalone Valkey

The chart's bundled `redis` subchart is a Bitnami chart that pulls `docker.io/bitnami/redis:*` — those tags were removed from Docker Hub in August 2025. We disable it and run a standalone Valkey (Redis-protocol-compatible) instead:

```bash
kubectl apply -f apps/charts/paperless-ngx-values/valkey.yaml
kubectl -n paperless wait --for=condition=Ready pod/paperless-valkey-0 --timeout=2m
```

The chart's PostgreSQL subchart has the same Bitnami-image issue. Our values pin `bitnamilegacy/postgresql:16.4.0-debian-12-r0` (Bitnami's archive registry) and accept the chart's "non-standard image" gate via `global.security.allowInsecureImages: true`.

## Install

```bash
cd ~/work/home/homelab
. apps/charts/paperless-ngx-values/.secrets.env

helm upgrade --install paperless-ngx gabe565/paperless-ngx \
  --version 0.24.1 \
  -n paperless --create-namespace \
  -f apps/charts/paperless-ngx-values/values.yaml \
  --set "env.PAPERLESS_SECRET_KEY=$PAPERLESS_SECRET_KEY" \
  --set "env.PAPERLESS_ADMIN_USER=admin" \
  --set "env.PAPERLESS_ADMIN_PASSWORD=$PAPERLESS_ADMIN_PASSWORD" \
  --set "env.PAPERLESS_ADMIN_MAIL=admin@chifor.dev" \
  --set "postgresql.global.postgresql.auth.password=$PAPERLESS_DB_PASSWORD" \
  --timeout 10m
```

## First login

- URL: https://paperless.chifor.dev
- Username: `admin`
- Password: `$PAPERLESS_ADMIN_PASSWORD` from `.secrets.env`

## Adding documents

1. **Web UI upload** — click "+ Add" on the Documents page
2. **Email forwarding** — configure SMTP in Settings → Mail Account, paperless will scan documents from email attachments
3. **Consume folder** — copy files into the `consume` PVC. Easiest way:
   ```bash
   # Copy a local PDF into the consume folder
   POD=$(kubectl -n paperless get pod -l app.kubernetes.io/name=paperless-ngx -o name | head -1)
   kubectl -n paperless cp ./scan.pdf $POD:/usr/src/paperless/consume/
   ```
   Paperless picks up new files in `consume/` within ~30 seconds, OCRs, tags, and stores them in `media/`.

## Required post-install env override (chart bug)

The `gabe565/paperless-ngx` chart 0.24.1 hardcodes several env vars in its
deployment template and **overrides whatever the user puts in the `env:`
values block**:

- `PAPERLESS_URL: http://{ingress host}` — always `http://`, can't override to `https://`
- `PAPERLESS_TIME_ZONE: UTC` — ignores `env.TZ`
- `PAPERLESS_CSRF_TRUSTED_ORIGINS`, `PAPERLESS_ALLOWED_HOSTS`, `PAPERLESS_USE_X_FORWARD_*` — silently dropped from `env:`

This breaks login behind a reverse proxy: Django CSRF rejects every POST with
`Origin checking failed - https://paperless.chifor.dev does not match any
trusted origins.`

Workaround (run after every `helm install` / `helm upgrade`):

```bash
kubectl -n paperless set env deploy/paperless-ngx \
  PAPERLESS_URL=https://paperless.chifor.dev \
  PAPERLESS_CSRF_TRUSTED_ORIGINS=https://paperless.chifor.dev \
  PAPERLESS_ALLOWED_HOSTS=paperless.chifor.dev \
  PAPERLESS_USE_X_FORWARD_HOST=true \
  PAPERLESS_USE_X_FORWARD_PORT=true \
  PAPERLESS_TRUSTED_PROXIES=10.42.0.0/16
```

`kubectl set env` patches the Deployment directly, triggering a rollout. The
patches survive pod restarts but are clobbered by `helm upgrade` — re-run
the snippet whenever you upgrade the chart.

For a permanent fix, either fork the chart with the hardcoded env removed,
or use a helm post-render script to drop the offending env entries before
they reach the cluster.

## Authentik OIDC integration

The Authentik provider + application + k8s Secret were created automatically by `apps/scripts/authentik-oidc-bootstrap.py`. Paperless 2.x uses django-allauth's `openid_connect` provider; the wiring is two env vars on the Deployment.

```bash
CLIENT_ID=$(kubectl -n paperless get secret authentik-oidc -o jsonpath='{.data.client-id}' | base64 -d)
CLIENT_SECRET=$(kubectl -n paperless get secret authentik-oidc -o jsonpath='{.data.client-secret}' | base64 -d)

# PAPERLESS_SOCIALACCOUNT_PROVIDERS is a JSON blob; the provider_id MUST be
# `authentik` to match the slug in the Authentik-side redirect URI
# (https://paperless.chifor.dev/accounts/oidc/authentik/login/callback/).
kubectl -n paperless set env deploy/paperless-ngx \
  PAPERLESS_APPS=allauth.socialaccount.providers.openid_connect \
  "PAPERLESS_SOCIALACCOUNT_PROVIDERS={\"openid_connect\":{\"APPS\":[{\"provider_id\":\"authentik\",\"name\":\"Authentik\",\"client_id\":\"$CLIENT_ID\",\"secret\":\"$CLIENT_SECRET\",\"settings\":{\"server_url\":\"https://authentik.chifor.dev/application/o/paperless/.well-known/openid-configuration\"}}]}}"
```

`kubectl set env` triggers a rollout. The login page now shows "Sign in with Authentik" alongside the local-account form. Existing Paperless users can link their account via Profile → Connected Accounts; new users are auto-provisioned on first sign-in (controlled by Paperless' `PAPERLESS_DISABLE_REGULAR_LOGIN`/`PAPERLESS_REDIRECT_LOGIN_TO_SSO` flags if you want to make SSO mandatory).

**Same caveat as the chart-bug section above: helm upgrade clobbers `kubectl set env` patches** — re-run after every chart upgrade.

## Quirks

- **Ingress class via annotation, not field**: chart 0.24.1 doesn't expose `className` / `ingressClassName` at the values level. We set the legacy annotation `kubernetes.io/ingress.class: cloudflare-tunnel` to force the operator to pick it up. Without this, the chart's Ingress falls through to the cluster's default IngressClass (Traefik in k3s) and the Cloudflare Tunnel never gets routed.
- **Bitnami image fallback**: `postgresql.image.repository: bitnamilegacy/postgresql` + `global.security.allowInsecureImages: true`. If you see `ImagePullBackOff` for the Postgres pod, the bitnamilegacy registry is also down — at that point the cleanest fix is to switch to CloudNativePG or another upstream Postgres operator. Document a migration plan when that day comes.

## Uninstall

```bash
helm uninstall paperless-ngx -n paperless
kubectl delete -f apps/charts/paperless-ngx-values/valkey.yaml
kubectl delete namespace paperless
# Manually delete CF DNS CNAME for paperless.chifor.dev.
```
