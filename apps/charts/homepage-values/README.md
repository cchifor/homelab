# homepage-values

[Homepage](https://gethomepage.dev/) — single dashboard for all the homelab services. No auth (LAN-only).

| | |
|---|---|
| Chart | `jameswynn/homepage` (`helm repo add jameswynn https://jameswynn.github.io/helm-charts`) |
| Pinned version | `2.1.0` (homepage v1.2.0) |
| Namespace | `homepage` |
| Exposure | **LAN-only** via Traefik + LE cert |
| URL | https://home.chifor.dev |

## Install

```bash
# Namespace first so the custom-css ConfigMap can be applied into it
kubectl create namespace homepage --dry-run=client -o yaml | kubectl apply -f -

# Windows 11 dark theme overlay (custom.css mounted via persistence.custom-css)
kubectl apply -f apps/manifests/homepage-custom-css/configmap.yaml

helm upgrade --install homepage jameswynn/homepage \
  --version 2.1.0 \
  -n homepage --create-namespace \
  -f apps/charts/homepage-values/values.yaml \
  --timeout 5m
```

## Windows 11 dark theme

The dashboard uses homepage's built-in `theme: dark` + `color: zinc` (closest neutral to Win11's warm-dark grays) with a custom CSS overlay that matches the Win11 File Explorer aesthetic — translucent surfaces, 8px rounded cards, Segoe UI Variable, `#4cc2ff` accent, subtle white-alpha borders.

CSS lives in `apps/manifests/homepage-custom-css/configmap.yaml`. Edits there require re-applying the ConfigMap and restarting the pod (homepage reads `custom.css` once at startup):

```bash
kubectl apply -f apps/manifests/homepage-custom-css/configmap.yaml
kubectl -n homepage rollout restart deploy/homepage
```

## Required: HOMEPAGE_ALLOWED_HOSTS

Homepage v1.0+ rejects every request whose `Host` header isn't on its allowlist (UI shows `Host validation failed. See logs for more details.`, container logs spell it out: `Host validation failed for: home.chifor.dev. Hint: Set the HOMEPAGE_ALLOWED_HOSTS environment variable…`). The chart's default `env:` declares the variable but leaves the value `null` — `values.yaml` here overrides the full env list to set it to `home.chifor.dev`. If you change the hostname, update the env entry in lockstep.

## Updating the dashboard

The whole dashboard config (services, bookmarks, widgets, layout) lives in the `config:` section of `values.yaml`. To add/edit:

1. Edit `apps/charts/homepage-values/values.yaml`
2. `helm upgrade homepage jameswynn/homepage -n homepage -f apps/charts/homepage-values/values.yaml`
3. Pod auto-reloads when ConfigMap changes (~30s).

The default config in this repo includes the apps deployed so far (Authentik, Vaultwarden, Gitea, Grafana, Uptime Kuma, Rancher). Add new entries as you deploy new apps.

## Widget integrations

Many homepage widgets (Gitea repo count, Uptime Kuma uptime %, Grafana dashboards count) need an API key per service. To wire them up, add per-service blocks under `config.services`:

```yaml
- Gitea:
    href: https://gitea.chifor.dev
    description: Git hosting
    icon: gitea.png
    widget:
      type: gitea
      url: https://gitea.chifor.dev
      key: <gitea-api-token>
```

Generate the API tokens via each service's UI, drop them into a `kubernetes_secret` you reference via `envFrom` in the homepage Deployment, or accept that they live in `values.yaml` (which is committed) — for a homelab, putting LAN-only API tokens in committed YAML is acceptable, but rotating them after exposure is a hassle.

## Uninstall

```bash
helm uninstall homepage -n homepage
kubectl delete namespace homepage
```
