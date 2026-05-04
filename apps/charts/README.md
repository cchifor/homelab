# apps/charts/

Locally-developed Helm charts. One chart per directory.

## Convention

Each chart follows the standard Helm 3 layout:

```
apps/charts/<chart-name>/
├── Chart.yaml          # apiVersion: v2, name, version (semver), appVersion
├── values.yaml         # Default values (annotated; treat as the chart's user docs)
├── values.schema.json  # OPTIONAL but recommended for non-trivial values
├── templates/
│   ├── _helpers.tpl    # Common template helpers (chart name, labels, etc.)
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── ingress.yaml    # If externally exposed
│   ├── configmap.yaml  # If non-secret config needed
│   ├── secret.yaml     # If secret values templated (prefer external secrets when sensible)
│   └── NOTES.txt       # Printed after `helm install` — quickstart for the user
├── templates/tests/
│   └── test-connection.yaml   # Optional: `helm test <release>` smoke test
└── README.md           # What this chart does, its values, expected dependencies
```

## Naming

- Chart directory name = chart name = installable name. Lowercase, hyphens.
- Chart `version` is the **chart's** version (bump on any chart change). Independent from `appVersion` (the application's version).
- Chart names that mirror an upstream project (e.g. `grafana`, `nextcloud`) should signal that it's local, e.g. by suffix or prefix: `homelab-grafana` or `nextcloud-custom`.

## Generating a new chart skeleton

```bash
cd apps/charts
helm create <chart-name>
# Strip the bundled defaults that don't fit your case (most likely most of them).
# Replace values.yaml with values that match the app you're packaging.
```

The skeleton from `helm create` includes a generic Deployment + Service + Ingress + serviceaccount + HPA wiring. For a home-lab chart you usually want to **delete** what you're not using rather than carry dead templates.

## Values style

- One value per knob. Don't bury config under nested objects unless it's a real grouping.
- Provide sensible defaults — `helm install <chart>` with no `--set` should produce a working release on this cluster.
- Default `image.tag` should be a pinned version, NOT `latest`.
- For storage, default `storageClassName: ""` (use cluster default — which is `longhorn` here) rather than hard-coding.
- For ingress hostnames, default `ingress.host: ""` and let users set their own.

## Testing a chart locally before installing

```bash
# Static checks (CI runs these too):
helm lint apps/charts/<name>
helm template apps/charts/<name>

# With override values:
helm template apps/charts/<name> -f my-values.yaml --debug

# Server-side dry-run (validates against the actual cluster's CRDs):
helm install <release> apps/charts/<name> --dry-run --debug
```

## Useful patterns for this cluster

**Ingress with TLS via cert-manager + Let's Encrypt (DNS-01 / Cloudflare):**

```yaml
# templates/ingress.yaml
{{- if .Values.ingress.enabled }}
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ include "<chart-name>.fullname" . }}
  annotations:
    # Default to letsencrypt-prod (real cert). Switch to letsencrypt-staging while
    # iterating to avoid burning the prod rate-limit (50 certs/week per registered domain).
    # Other available ClusterIssuer: selfsigned-issuer (no LE round-trip; useful when
    # the app's hostname isn't under {{ tofu output letsencrypt_base_domain }}).
    cert-manager.io/cluster-issuer: {{ .Values.ingress.clusterIssuer | default "letsencrypt-prod" }}
spec:
  ingressClassName: traefik       # k3s built-in
  tls:
    - hosts: [ {{ .Values.ingress.host }} ]   # e.g. vaultwarden.chifor.dev
      secretName: {{ include "<chart-name>.fullname" . }}-tls
  rules:
    - host: {{ .Values.ingress.host }}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: {{ include "<chart-name>.fullname" . }}
                port: { number: {{ .Values.service.port }} }
{{- end }}
```

cert-manager watches Ingresses with this annotation, automatically creates a
`Certificate` resource that requests `<.Values.ingress.host>` from the named
issuer, performs the DNS-01 challenge via Cloudflare, and stores the cert in
the named `secretName`. Traefik picks up the Secret and serves TLS — no
per-app cert-manager configuration beyond the annotation.

The `host` value just needs to be under the base domain configured in
`platform/` (see `tofu -chdir=platform output letsencrypt_base_domain`).
Apps don't need their own DNS records as long as the wildcard A record
(`*.<base_domain>` → Traefik LB IP) is in place.

**Ingress for a public app (Cloudflare Tunnel — fully automated):**

For apps exposed via Cloudflare Tunnel, the Ingress is simpler — no
cert-manager annotation, no `tls:` block — and the **only difference** from
a LAN Ingress is the `ingressClassName: cloudflare-tunnel`. The operator
(`cloudflare-tunnel-ingress-controller` in the platform) watches Ingresses
of this class and auto-configures the tunnel public hostname + DNS CNAME:

```yaml
# templates/ingress.yaml — public-app variant
{{- if .Values.ingress.enabled }}
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ include "<chart-name>.fullname" . }}
spec:
  ingressClassName: cloudflare-tunnel    # ← operator picks this up
  rules:
    - host: {{ .Values.ingress.host }}   # e.g. vaultwarden.chifor.dev
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: {{ include "<chart-name>.fullname" . }}
                port: { number: {{ .Values.service.port }} }
{{- end }}
```

`helm install` → operator detects the Ingress → adds the public hostname
to the tunnel → creates the DNS CNAME → traffic flows: user → CF edge
(TLS terminated, real cert) → tunnel → cloudflared → your pod's Service.

`helm uninstall` → operator removes the public hostname AND the DNS CNAME.
Pure GitOps, zero dashboard interaction.

A reasonable chart pattern is to gate this on a values flag so the same
chart can deploy LAN-only or public depending on the install:

```yaml
# values.yaml
ingress:
  enabled:  true
  host:     ""             # required from caller
  exposure: lan            # "lan" → traefik + LE; "public" → cloudflare-tunnel
  clusterIssuer: letsencrypt-prod   # only used when exposure=lan
```

Then `templates/ingress.yaml` branches on `.Values.ingress.exposure`:
- `lan` → `ingressClassName: traefik` + LE annotation + `tls:` block
- `public` → `ingressClassName: cloudflare-tunnel` + no annotation, no `tls:`

**PVC using the default StorageClass (Longhorn):**

```yaml
# templates/pvc.yaml — values.persistence.enabled gates the whole thing
{{- if .Values.persistence.enabled }}
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {{ include "<chart-name>.fullname" . }}
spec:
  accessModes: [ {{ .Values.persistence.accessMode | default "ReadWriteOnce" }} ]
  {{- with .Values.persistence.storageClassName }}
  storageClassName: {{ . }}
  {{- end }}
  resources:
    requests:
      storage: {{ .Values.persistence.size | default "10Gi" }}
{{- end }}
```

**MinIO bucket access for backups (using the platform-deployed MinIO):**

The MinIO root creds live in `tofu output -raw minio_root_password`. For app access, generally provision a per-app MinIO user via `mc` (out of scope for the chart itself) and pass the resulting access keys via a Secret. Don't bake MinIO root creds into chart defaults.

## CI

Every chart under `apps/charts/*/` is exercised by `.github/workflows/ci.yml` on PR + push:

- `helm lint <chart>` — catches Chart.yaml schema issues, missing required fields, basic template errors
- `helm template <chart>` — catches render-time errors (e.g. references to undefined values, broken `range`, missing functions)

If you have values overrides that change required-vs-optional shape, add a `values-test.yaml` and the CI step can be extended to `helm template <chart> -f values-test.yaml` to catch those too.
