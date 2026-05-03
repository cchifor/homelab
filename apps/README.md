# apps/

Application workloads that run *on* the cluster provisioned by [`../platform/`](../platform/).

```
apps/
├── charts/      ← Locally-developed Helm charts (see ./charts/README.md)
└── manifests/   ← Raw k8s YAML for things that don't warrant a chart
    └── dind-runner/   ← Privileged docker-in-docker example
```

## When to use a chart vs a raw manifest

| | Chart (`apps/charts/<name>/`) | Manifest (`apps/manifests/<name>/`) |
|---|---|---|
| **Multiple environments** with different values | ✅ | ❌ painful |
| **Templated values** (replicas, hostnames, image tags) | ✅ | ❌ |
| **One-off / always-the-same workload** | overkill | ✅ |
| **Smoke tests / examples** | overkill | ✅ |
| **Apps you want to redistribute or share** | ✅ | ❌ |
| **Reuse third-party chart with overrides** | install upstream chart with your own `values.yaml` (no local chart needed) | n/a |

If in doubt: start with a manifest. Promote to a chart when you find yourself copy-pasting it for the second deployment.

## Installing a local chart

```bash
# From the repo root, against the cluster on the home-lab kubeconfig:
helm install <release-name> ./apps/charts/<chart-name>
helm upgrade <release-name> ./apps/charts/<chart-name>     # changes
helm uninstall <release-name>                              # cleanup

# With values overrides:
helm install <release> ./apps/charts/<chart> -f my-values.yaml --set image.tag=v1.2.3
```

The cluster's default namespace is `default`; pass `-n <namespace> --create-namespace` if your chart belongs elsewhere.

## Installing an upstream chart with our values

For third-party apps (Grafana, Prometheus, Vaultwarden, etc.), we don't fork the upstream chart — we keep just the values overrides:

```bash
# Recommended pattern: per-app values in apps/charts/<app>-values/values.yaml
mkdir -p apps/charts/grafana-values
cat > apps/charts/grafana-values/values.yaml <<EOF
adminPassword: ...
persistence:
  enabled: true
  storageClassName: longhorn
EOF

helm repo add grafana https://grafana.github.io/helm-charts
helm install grafana grafana/grafana \
  -n monitoring --create-namespace \
  -f apps/charts/grafana-values/values.yaml
```

When the upstream chart upgrades, your overrides in `apps/charts/grafana-values/values.yaml` keep working unless they remove the field you're overriding.

## Applying a manifest

```bash
kubectl apply -f apps/manifests/<name>/

# Tear down:
kubectl delete -f apps/manifests/<name>/
```

## Storage available to apps

The cluster has two `StorageClass` options once `platform/` is fully applied:

| Class | Provisioner | Replication | Best for |
|---|---|---|---|
| `longhorn` (default) | Longhorn | 2 replicas across workers | Stateful apps that should survive a worker dying |
| `local-path` | rancher.io/local-path | none — node-local | Caches, scratch, throw-away PVCs |

Your chart / manifest can either omit `storageClassName` (gets the default `longhorn`) or pin one explicitly.

## What's already deployed by `platform/` (don't duplicate)

These are foundational platform services managed by Terraform — apps that depend on them get the dependency for free, no need to install:

| | Where | What apps get |
|---|---|---|
| **cert-manager** | `cert-manager` namespace | A `selfsigned-issuer` `ClusterIssuer` ready to use; add `cert-manager.io/cluster-issuer: selfsigned-issuer` annotation on your `Ingress` |
| **Traefik** | `kube-system` (k3s built-in) | `IngressClass: traefik` is the default; `EXTERNAL-IP` published on every node IP via klipper-lb |
| **Longhorn** | `longhorn-system` | Default StorageClass + a `BackupTarget` pointing at MinIO |
| **MinIO** | LXC at `192.168.0.186:9000` | S3 endpoint for backups, build artefacts, etc. Creds in `tofu output -raw minio_root_password` |
| **Rancher** | `cattle-system` | Web UI at `https://rancher.lan` — can browse / install apps from there too |

## CI checks that run on PRs to `apps/`

The [`.github/workflows/ci.yml`](../.github/workflows/ci.yml) workflow runs three apps-related jobs:

- `helm lint` on every chart under `apps/charts/*/` (skipped if no charts yet)
- `helm template` (catches render-time errors `lint` misses)
- `kubectl --dry-run=client apply -f` on every manifest under `apps/manifests/*/*.yaml`

So invalid YAML, missing required values, and obvious schema errors are caught before merge.
