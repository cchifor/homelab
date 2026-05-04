# kube-prometheus-stack-values

Upstream-chart-with-our-values pattern for the Prometheus operator + Grafana + Alertmanager + node-exporter + kube-state-metrics — full-fat observability for the cluster.

| | |
|---|---|
| Chart | `prometheus-community/kube-prometheus-stack` (`helm repo add prometheus-community https://prometheus-community.github.io/helm-charts`) |
| Pinned version | `84.5.0` |
| Namespace | `monitoring` |
| Exposure | **Grafana LAN-only** (LE cert via cert-manager); Prometheus + Alertmanager port-forward only |
| Grafana URL | https://grafana.chifor.dev |

## First install

```bash
cd ~/work/home/homelab
. apps/charts/kube-prometheus-stack-values/.secrets.env

helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --version 84.5.0 \
  -n monitoring --create-namespace \
  -f apps/charts/kube-prometheus-stack-values/values.yaml \
  --set "grafana.adminPassword=$GRAFANA_ADMIN_PASSWORD" \
  --timeout 15m
```

## Access

- **Grafana** — https://grafana.chifor.dev (real LE cert, LAN-only)
  - User: `admin`, password: `$GRAFANA_ADMIN_PASSWORD` from `.secrets.env`
  - Datasources: Prometheus + Alertmanager auto-wired
  - Default dashboards: cluster, nodes, pods, kube-state-metrics — all pre-installed
- **Prometheus** (no ingress; port-forward when needed):
  ```bash
  kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
  # then browse http://localhost:9090
  ```
- **Alertmanager** (no ingress):
  ```bash
  kubectl -n monitoring port-forward svc/kube-prometheus-stack-alertmanager 9093:9093
  ```

## Notable values choices

- **Storage**: Prometheus 50 GiB on Longhorn, retained 15d / 40 GiB cap (whichever first). Alertmanager 5 GiB.
- **`*SelectorNilUsesHelmValues: false`**: by default the operator only watches ServiceMonitors with the chart's release label, silently dropping third-party monitors. We disable that so any ServiceMonitor in the cluster gets scraped.
- **k3s-specific disables**: kubeControllerManager, kubeScheduler, kubeProxy, kubeEtcd are disabled — k3s embeds these inside `k3s-server` and doesn't expose them on standard ports, so the default scrape jobs would just produce errors.

## Upgrade

```bash
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --version <new-version> \
  -n monitoring \
  -f apps/charts/kube-prometheus-stack-values/values.yaml \
  --set "grafana.adminPassword=$GRAFANA_ADMIN_PASSWORD"
```

CRD updates often need to be applied separately when bumping major versions; check the chart release notes.

## Uninstall

```bash
helm uninstall kube-prometheus-stack -n monitoring
kubectl delete namespace monitoring   # cleans PVCs (Longhorn volumes will be released)

# CRDs are not deleted by helm uninstall; remove manually if desired:
kubectl get crd -o name | grep monitoring.coreos.com | xargs kubectl delete
```
