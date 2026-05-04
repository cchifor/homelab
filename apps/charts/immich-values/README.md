# immich-values

Self-hosted Google Photos alternative — face/object AI search, mobile auto-upload, sharing.

| | |
|---|---|
| Chart | `immich/immich` (`helm repo add immich https://immich-app.github.io/immich-charts`) |
| Pinned version | `0.11.1` (Immich v2.6.3) |
| Namespace | `immich` |
| Exposure | **Public via Cloudflare Tunnel** at https://immich.chifor.dev |
| Database | CloudNativePG cluster `immich-postgres` (in `immich` namespace) with VectorChord + pgvector + cube + earthdistance extensions |
| Library PVC | 100 GiB Longhorn (pre-created) |

## Pre-install: Postgres cluster + library PVC

The chart no longer bundles PostgreSQL (since 0.10.0) — it requires an external Postgres with VectorChord (Immich's vector extension since v1.133), pgvector, cube, and earthdistance. We deploy via CloudNativePG operator + a tensorchord image that ships VectorChord + pgvector.

**Step 1: install CloudNativePG operator** (one-time per cluster):

```bash
helm repo add cnpg https://cloudnative-pg.github.io/charts
helm upgrade --install cnpg cnpg/cloudnative-pg \
  --version 0.28.0 \
  -n cnpg-system --create-namespace --timeout 5m
kubectl label namespace cnpg-system chifor.dev/tier=platform --overwrite
```

**Step 2: deploy the immich Postgres cluster + namespace + library PVC:**

```bash
kubectl apply -f apps/manifests/immich-postgres/cluster.yaml

# Pre-create the Immich library PVC (chart requires existingClaim — won't auto-create)
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: immich-library
  namespace: immich
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: longhorn
  resources:
    requests:
      storage: 100Gi
EOF

kubectl -n immich wait --for=condition=Ready clusters.postgresql.cnpg.io/immich-postgres --timeout=8m
```

CNPG auto-creates Secret `immich-postgres-app` with username + password the chart references.

The `postInitApplicationSQL` block in the cluster manifest creates `vector` (pgvector), `vchord` (VectorChord), `cube`, and `earthdistance` extensions on first init — all required by Immich.

## Install

```bash
helm upgrade --install immich immich/immich \
  --version 0.11.1 \
  -n immich \
  -f apps/charts/immich-values/values.yaml \
  --timeout 15m
```

## Validation

```bash
kubectl -n immich get pods   # all 4 should be Running:
                              #   immich-postgres-1
                              #   immich-server-*
                              #   immich-machine-learning-*
                              #   immich-valkey-*

curl -sI https://immich.chifor.dev/  # expect 200
```

## First-run setup

Browse https://immich.chifor.dev — the web UI prompts for admin user creation on first launch. **No bootstrap admin** (unlike most apps) — you set the credentials directly via the web wizard.

After creating admin, in **Settings → Server**:
- External Domain: `https://immich.chifor.dev`

Mobile app: install Immich from app store → server URL = `https://immich.chifor.dev`.

## Adding photos

Three ways:
1. **Web upload** — drag-and-drop in browser
2. **Mobile auto-upload** — install Immich app, sign in, enable backup
3. **CLI** — `immich-go` or `immich-cli` for bulk imports

The library lives at PVC `immich-library` (100 GiB initially — expand by editing the PVC). All Immich servers and microservices share access via ReadWriteOnce attachment to the same node.

## Quirks worth knowing

1. **Chart removed bundled Postgres in 0.10.0** — must use external CNPG (or other Postgres with VectorChord+pgvector+cube+earthdistance).

2. **Bjw-s app-template values structure** — env vars go under `<component>.controllers.main.containers.main.env`, not top-level `env:`. See `values.yaml` for the pattern.

3. **Extension name vs package name**: `CREATE EXTENSION pgvector` fails — the package is pgvector but the extension name is `vector`. CREATE the right name in postInitApplicationSQL.

4. **postInitSQL vs postInitApplicationSQL**: CNPG's `postInitSQL` runs against `postgres` (system DB); `postInitApplicationSQL` runs against the app DB. Extensions Immich uses must be in `postInitApplicationSQL`.

5. **earthdistance + cube need superuser**: the `immich` user can't `CREATE EXTENSION` for those — they must be created via `postInitApplicationSQL` (which CNPG runs as `postgres`/superuser).

## Tear down

```bash
helm uninstall immich -n immich
kubectl -n immich delete clusters.postgresql.cnpg.io/immich-postgres
kubectl delete namespace immich
# Manually delete CF DNS CNAME for immich.chifor.dev (operator orphans it).

# Optional: uninstall CNPG operator (only if no other apps use it)
helm uninstall cnpg -n cnpg-system
```
