# Incus monitoring — Prometheus scrape + Grafana dashboard

Hooks the 4-node Incus cluster into the existing kube-prometheus-stack so
fleet metrics (CPU, memory, disk, network, per-instance + aggregate) show up
in the same Grafana you already use for k8s.

## Architecture

```
┌────────────────┐  HTTPS + mTLS    ┌─────────────────────┐
│ Prometheus     │ ───────────────► │ Incus members (×4)  │
│ (monitoring/)  │  /1.0/metrics    │  rdxa1..rdxa4       │
└──────┬─────────┘                  │  trust type=metrics │
       │                            └─────────────────────┘
       ▼
┌────────────────┐
│ Grafana        │  ◄─ dashboard ConfigMap (this dir)
└────────────────┘
```

## Files

| File | Applied as |
|---|---|
| `scrapeconfig.yaml` | `ScrapeConfig` in `monitoring/` (picked up by the Prometheus CR via `release: kube-prometheus-stack` selector) |
| `dashboard-incus-fleet.json` | Embedded into a `ConfigMap` (`incus-fleet-dashboard`) with label `grafana_dashboard: "1"` so the Grafana sidecar auto-imports it |
| `incus-scrape-tls` (Secret) | Created out-of-band; holds the Prometheus client cert + key. Not in this repo — the private key would leak. Regenerate per "Regenerating the cert" below if lost. |

## One-time setup

1. **Generate Prometheus client cert/key** on your workstation:
   ```bash
   mkdir -p /tmp/incus-mon && cd /tmp/incus-mon
   MSYS_NO_PATHCONV=1 openssl req -x509 -newkey rsa:4096 \
     -keyout client.key -out client.crt \
     -sha256 -days 3650 -nodes \
     -subj "/CN=prometheus-incus-scraper"
   ```

2. **Register the cert on Incus** with metrics-only trust (scoped — can read
   metrics, cannot create/modify VMs):
   ```bash
   scp client.crt c4@192.168.0.131:/tmp/prom-scraper.crt
   ssh c4@192.168.0.131 'sudo incus config trust add-certificate \
     --type=metrics --name=prometheus-scraper /tmp/prom-scraper.crt; \
     rm /tmp/prom-scraper.crt'
   ```
   The trust replicates to all cluster members automatically.

3. **Create the k8s Secret** Prometheus will mount:
   ```bash
   kubectl -n monitoring create secret generic incus-scrape-tls \
     --from-file=client.crt=client.key=client.crt \
     --from-file=client.key=client.key
   ```

4. **Apply the ScrapeConfig + dashboard ConfigMap:**
   ```bash
   kubectl apply -f scrapeconfig.yaml
   kubectl -n monitoring create configmap incus-fleet-dashboard \
     --from-file=dashboard-incus-fleet.json \
     --dry-run=client -o yaml | \
     kubectl label --local -f - --dry-run=client -o yaml \
       grafana_dashboard=1 | \
     kubectl apply -f -
   ```

5. **Shred the local key copy** (it's now in the Secret):
   ```bash
   shred -u client.key 2>/dev/null || rm -f client.key
   ```

## Verifying

```bash
# Prometheus should show 4 targets under job=incus, all UP:
#   Prometheus UI → Status → Targets → search "incus"
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090

# Or query directly:
kubectl -n monitoring exec -ti prometheus-kube-prometheus-stack-prometheus-0 -c prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/targets?state=active' \
  | grep -o '"scrapeUrl":"[^"]*incus[^"]*"' | sort -u
```

Grafana dashboard appears under "Incus" tag (auto-imported by the sidecar
within ~30 s of the ConfigMap landing).

## Regenerating the cert

If the Secret is lost or the cert needs rotation:

1. Repeat steps 1–4 above.
2. Remove the old cert from Incus's trust list:
   ```bash
   ssh c4@192.168.0.131 'sudo incus config trust list | grep prometheus'
   ssh c4@192.168.0.131 'sudo incus config trust remove <old-fingerprint>'
   ```

## Host-level metrics

All 4 rdxa hosts (rdxa1..4) run k3s-agent + Incus side-by-side, so the
kube-prometheus-stack node-exporter daemonset already reaches every host.
The fleet dashboard above queries those daemonset endpoints by IP; host
CPU/mem/disk/network all flow through that channel. No standalone scrape
target needed (the old `q6a-1-node-exporter-scrapeconfig.yaml` was retired
on 2026-05-19 when q6a-1 became rdxa1 with k3s installed alongside Incus).
