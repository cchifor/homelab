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

# Custom dashboards (Longhorn, cert-manager, Homelab Overview) and the
# ServiceMonitors that feed them:
kubectl apply -k apps/manifests/grafana-dashboards/
kubectl apply -f apps/manifests/servicemonitors/

# Org-level Grafana defaults (home dashboard) -- not chart-managed,
# stored in Grafana's DB. Re-run any time the Grafana PV is wiped.
GRAFANA_URL=https://grafana.chifor.dev \
GRAFANA_ADMIN_PASSWORD="$GRAFANA_ADMIN_PASSWORD" \
python apps/scripts/grafana-defaults.py
```

## Admin password drift after first install

`grafana.adminPassword` is only honoured at **first install** -- subsequent helm upgrades don't push it back into Grafana's DB. If basic-auth login starts failing with "invalid password", reset it back via grafana-cli inside the pod:

```bash
POD=$(kubectl -n monitoring get pod \
  -l app.kubernetes.io/name=grafana,app.kubernetes.io/instance=kube-prometheus-stack \
  -o jsonpath='{.items[0].metadata.name}')
kubectl -n monitoring exec $POD -c grafana -- \
  /usr/share/grafana/bin/grafana cli --homepath=/usr/share/grafana \
  admin reset-admin-password "$GRAFANA_ADMIN_PASSWORD"
kubectl -n monitoring rollout restart deploy/kube-prometheus-stack-grafana
```

Brute-force protection on `admin` accumulates across pod restarts (it's stored in Grafana's DB, not memory) -- if you've triggered the lockout, wait ~5 min after the last failed attempt before retrying.

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
