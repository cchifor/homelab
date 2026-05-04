# apps/

Application workloads that run *on* the cluster provisioned by [`../platform/`](../platform/).

## Namespace convention

Every namespace is labeled `chifor.dev/tier` to distinguish app vs platform at a glance:

```bash
kubectl get ns -l chifor.dev/tier=app           # the apps in this directory
kubectl get ns -l chifor.dev/tier=platform      # cluster foundation (cert-manager, longhorn, monitoring, velero, cloudflare-tunnel-..., rancher, etc.)
```

Each new app lives in **its own namespace** (`<app-name>`) for RBAC/NetworkPolicy/ResourceQuota isolation and Velero restore granularity. After deploying a new app, label its namespace:

```bash
kubectl label namespace <app-name> chifor.dev/tier=app --overwrite
```


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
| **cert-manager** | `cert-manager` namespace | Three `ClusterIssuer`s ready to use — annotate your `Ingress` with `cert-manager.io/cluster-issuer: <name>`: <br>• `letsencrypt-prod` — real Let's Encrypt cert via DNS-01 / Cloudflare (default for any host under the configured base domain — see `tofu -chdir=../platform output letsencrypt_base_domain`) <br>• `letsencrypt-staging` — same, but LE staging endpoint (untrusted certs, very loose rate limits — use while debugging) <br>• `selfsigned-issuer` — local self-signed cert, for hosts outside the base domain or fully-offline apps |
| **Traefik** | `kube-system` (k3s built-in) | `IngressClass: traefik` is the default; `EXTERNAL-IP` published on every node IP via klipper-lb |
| **Longhorn** | `longhorn-system` | Default StorageClass + a `BackupTarget` pointing at MinIO |
| **MinIO** | LXC at `192.168.0.186:9000` | S3 endpoint for backups, build artefacts, etc. Creds in `tofu output -raw minio_root_password` |
| **Rancher** | `cattle-system` | Web UI at `https://rancher.lan` — can browse / install apps from there too |
| **Cloudflare Tunnel Ingress Controller** | `cloudflare-tunnel-ingress-controller` namespace (when enabled in platform) | Outbound tunnel to Cloudflare's edge + a controller that watches Ingresses with `ingressClassName: cloudflare-tunnel` and auto-configures the tunnel public hostname AND the DNS CNAME. Per-app expose = one Ingress; per-app teardown = `helm uninstall`. |

## Two ways to expose an app

Apps in this cluster fall into one of two access patterns:

### A. LAN-only (admin / internal tools)

Use this for apps you only access from inside your home network — Rancher UI, Longhorn UI, monitoring dashboards, internal admin tools.

- DNS: relies on the wildcard `*.chifor.dev → 192.168.0.187` A record (gray cloud / DNS-only) so your LAN's resolver answers with the Traefik LB IP.
- TLS: cert-manager issues a real LE cert via DNS-01 (the cert is real even though the IP is private — DNS-01 only needs TXT-record control, not inbound reachability).
- Annotation: `cert-manager.io/cluster-issuer: letsencrypt-prod` on the Ingress.
- Off your LAN, the hostname resolves to an unroutable RFC1918 IP — apps are unreachable. That's the point.

### B. Public via Cloudflare Tunnel (apps you need from anywhere)

Use this for apps you want reachable from your phone, a friend's laptop, or anywhere — Vaultwarden, dashboards you want to share, etc.

- DNS + tunnel hostname: **fully automated** by the cloudflare-tunnel-ingress-controller. The operator watches your app's Ingress and configures both the tunnel and the DNS CNAME for you.
- TLS: terminated by Cloudflare at their edge with their universal cert. **No** cert-manager annotation, **no** `tls:` block on the Ingress.
- Setup per app — just deploy with the right `ingressClassName`:

  ```yaml
  apiVersion: networking.k8s.io/v1
  kind: Ingress
  metadata:
    name: vaultwarden
  spec:
    ingressClassName: cloudflare-tunnel    # ← the operator picks this up
    rules:
      - host: vaultwarden.chifor.dev
        http:
          paths:
            - path: /
              pathType: Prefix
              backend:
                service:
                  name: vaultwarden
                  port: { number: 80 }
  ```

  `helm install` → operator detects the Ingress → adds the public hostname to the tunnel → creates the DNS CNAME → traffic flows.

  **On `helm uninstall` (or Ingress deletion)**, the operator removes the tunnel public hostname rule (so the URL stops resolving to anything useful — incoming traffic falls through to the tunnel's catch-all `404`) but leaves the DNS CNAME in Cloudflare. To fully clean up, also delete the DNS record manually in CF dashboard, or via API:

  ```bash
  source platform/.env
  ZONE_ID=$(curl -sS -H "Authorization: Bearer $TF_VAR_cloudflare_api_token" \
    "https://api.cloudflare.com/client/v4/zones?name=chifor.dev" \
    | python -c "import sys,json; print(json.load(sys.stdin)['result'][0]['id'])")
  REC_ID=$(curl -sS -H "Authorization: Bearer $TF_VAR_cloudflare_api_token" \
    "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?name=<app>.chifor.dev" \
    | python -c "import sys,json; print(json.load(sys.stdin)['result'][0]['id'])")
  curl -sS -X DELETE -H "Authorization: Bearer $TF_VAR_cloudflare_api_token" \
    "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$REC_ID"
  ```

  The orphan CNAME is harmless (points to a tunnel route that 404s) but accumulates over time if you spin apps up and down often.

### Gotcha: the operator skips headless Services

If your chart creates the backing Service with `clusterIP: None` (e.g. Gitea's
`service.http.clusterIP: None` default), the operator logs

```
extract exposures from ingress, skipped — service has None for cluster ip,
headless service is not supported
```

…and never creates the tunnel route or DNS CNAME. Override the chart's
`clusterIP` to an empty string (`""`) to get a real ClusterIP. The
`apps/charts/gitea-values/values.yaml` shows the pattern.

Per-app DNS CNAMEs (operator-created) override the wildcard A record from option A, so the same domain naturally splits — `rancher.chifor.dev` keeps pointing at the LAN IP, `vaultwarden.chifor.dev` flows through the tunnel.

### Picking which to use

| If the app is… | Use |
|---|---|
| For your own admin / debugging only, never accessed from outside | A (LAN-only) |
| Something you want from your phone or while traveling | B (tunnel) |
| Streaming significant video (Plex, Jellyfin) | A (CF TOS prohibits heavy media via tunnel — keep on LAN + Tailscale for remote) |
| You're not sure | A first, promote to B later if you need it (changing is just adding the public hostname in CF + dropping the cert-manager annotation) |

## CI checks that run on PRs to `apps/`

The [`.github/workflows/ci.yml`](../.github/workflows/ci.yml) workflow runs three apps-related jobs:

- `helm lint` on every chart under `apps/charts/*/` (skipped if no charts yet)
- `helm template` (catches render-time errors `lint` misses)
- `kubectl --dry-run=client apply -f` on every manifest under `apps/manifests/*/*.yaml`

So invalid YAML, missing required values, and obvious schema errors are caught before merge.
