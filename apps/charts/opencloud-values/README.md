# opencloud-values

Self-hosted file sync + collaboration (Nextcloud alternative). Replaces the Nextcloud install we removed.

| | |
|---|---|
| Chart | **`opencloud-eu/helm`** (cloned from GitHub — official chart repo was archived 2025-11-26 by the maintainers; OCI registry returns 403 anonymous) |
| Vendored copy | None — install procedure clones the upstream repo to `/tmp` each time. See "Install" below. Consider vendoring the chart .tgz into this directory for full reproducibility. |
| Pinned commit | (currently `main`; pin to a specific git SHA for reproducibility) |
| Namespace | `opencloud` |
| Components | OpenCloud (web + API), Keycloak (OIDC IdP), PostgreSQL (for Keycloak), MinIO (S3 storage), Tika (full-text search) |
| Public hostnames | `cloud.chifor.dev` (OpenCloud), `kc-cloud.chifor.dev` (Keycloak — required for OIDC redirects from browser) |
| Disabled | OnlyOffice + Collabora doc editors (~3 GiB combined RAM — re-enable when needed) |

## Important context

The official `opencloud-eu/helm` GitHub repo was **archived November 26, 2025** by the OpenCloud maintainers. Their statement: "Due to the high amount of AI generated contributions and poor maintenance, this repository has been archived." Production helm charts are now commercial-only — contact `sales@opencloud.eu`.

The chart files themselves remain readable in the archived repo, so we install from a local `git clone`. Long-term, either:
- Vendor a tagged release as a `.tgz` in this directory and install from it, or
- Use a community fork (community-maintained), or
- Switch to OpenCloud's Docker Compose deployment in an LXC (similar to `proxmox_lxc_plex`)

## Install

```bash
# 1. Clone the (archived but readable) chart
cd /tmp
rm -rf opencloud-helm
git clone --depth=1 https://github.com/opencloud-eu/helm.git opencloud-helm

# 2. Generate secrets if not yet present
cd ~/work/home/homelab
[ -f apps/charts/opencloud-values/.secrets.env ] || cat > apps/charts/opencloud-values/.secrets.env <<EOF
OC_ADMIN_PASSWORD=$(openssl rand -hex 16)
OC_KEYCLOAK_ADMIN_PASSWORD=$(openssl rand -hex 16)
OC_POSTGRES_PASSWORD=$(openssl rand -hex 16)
OC_MINIO_ROOT_PASSWORD=$(openssl rand -hex 16)
EOF
chmod 600 apps/charts/opencloud-values/.secrets.env

. apps/charts/opencloud-values/.secrets.env

# 3. Install from cloned local path
cd /tmp/opencloud-helm/charts/opencloud
helm dependency update .

helm upgrade --install opencloud . \
  -n opencloud --create-namespace \
  -f ~/work/home/homelab/apps/charts/opencloud-values/values.yaml \
  --set "opencloud.adminPassword=$OC_ADMIN_PASSWORD" \
  --set "keycloak.internal.adminPassword=$OC_KEYCLOAK_ADMIN_PASSWORD" \
  --set "postgres.password=$OC_POSTGRES_PASSWORD" \
  --timeout 15m

cd ~/work/home/homelab
kubectl label namespace opencloud chifor.dev/tier=app --overwrite

# 4. Apply our hand-rolled Ingresses (chart's `ingress.enabled` doesn't actually
#    create Ingresses in this chart version — only logs a reminder).
kubectl apply -f apps/charts/opencloud-values/ingresses.yaml

# 5. Fix Keycloak entrypoint script CRLF line endings
#    (the chart's ConfigMap is rendered with CRLF on Windows operator
#     machines, breaking Keycloak's launch script with errors like
#     "Unknown option: '--import-realm'" — the trailing \r mangles the flag)
SCRIPT=$(kubectl -n opencloud get configmap opencloud-keycloak-script -o jsonpath='{.data.docker-entrypoint-override\.sh}')
SCRIPT_FIXED=$(echo "$SCRIPT" | tr -d '\r')
kubectl -n opencloud create configmap opencloud-keycloak-script \
  --from-literal=docker-entrypoint-override.sh="$SCRIPT_FIXED" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n opencloud rollout restart deploy/opencloud-keycloak
```

## First login

After install:
- URL: **https://cloud.chifor.dev**
- Login redirects to Keycloak at https://kc-cloud.chifor.dev (browser-side redirect; Keycloak must be reachable from where you log in from).
- **OpenCloud admin** (the user that signs into OpenCloud itself):
  - Username: `admin`
  - Password: `$OC_ADMIN_PASSWORD` from `.secrets.env`
- **Keycloak admin** (for managing Keycloak itself — separate from OpenCloud admin):
  - URL: https://kc-cloud.chifor.dev/admin
  - Realm: `master`
  - Username: `admin`
  - Password: `$OC_KEYCLOAK_ADMIN_PASSWORD` from `.secrets.env`

Both passwords should be rotated via their respective UIs after first login.

## Quirks to know about

1. **Chart repo archived.** Reproducibility depends on either vendoring the chart locally or pinning to a specific git SHA when cloning.
2. **Chart's `ingress.enabled` is misleading** — doesn't auto-create Ingress resources in this chart version. We hand-roll them in `ingresses.yaml`.
3. **CRLF in Keycloak entrypoint script** when rendered on Windows. Without the line-ending fix, Keycloak crashloops with "Unknown option: '--import-realm'".
4. **Search service hard-depends on Tika.** Disabling Tika cascade-fails the OpenCloud supervisor (5 retries → backoff state, never recovers). Tika is ~200 MB; cheap to leave on.
5. **Internal MinIO** for S3 storage — could swap for the platform's existing MinIO LXC at 192.168.0.186, but the chart bootstraps buckets + IAM creds tightly to its own MinIO. Defer until you outgrow internal.
6. **Two public hostnames** (`cloud` + `kc-cloud`) needed because Keycloak OIDC requires browser-reachable redirects. Both are auto-managed by the cloudflare-tunnel-ingress-controller.

## Tear down

```bash
helm uninstall opencloud -n opencloud
kubectl delete -f apps/charts/opencloud-values/ingresses.yaml
kubectl delete namespace opencloud
# Manually delete CF DNS CNAMEs for cloud.chifor.dev + kc-cloud.chifor.dev
# (operator orphans them; or wait for the dns-cleanup CronJob next hourly run)
```
