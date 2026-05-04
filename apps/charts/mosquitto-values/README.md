# mosquitto-values

Status: **chart-only / scaled to 0**. Installed and validated; replicas set to 0.

| | |
|---|---|
| Chart | `k8s-at-home/mosquitto` (`helm repo add k8s-at-home https://k8s-at-home.com/charts/`) |
| Pinned version | `4.8.2` (Mosquitto 2.0.20) |
| Namespace | `mosquitto` |
| Exposure | Cluster-internal MQTT broker (no LAN/public ingress) — accessible at `mosquitto.mosquitto.svc.cluster.local:1883` |

## Heads-up: chart is from an archived repo

The `k8s-at-home` charts are deprecated (their org sunset the chart repo in favor of bjw-s app-template). The chart still installs cleanly, but won't get future updates. When you actually deploy MQTT for production homelab use, consider migrating to a maintained alternative (e.g., a hand-rolled Deployment + ConfigMap, or the `bjw-s/app-template` chart).

## Re-activate

```bash
kubectl -n mosquitto scale deployment/mosquitto --replicas=1
```

## Quirk: chart's configMap mount fails on read-only image

The k8s-at-home chart's default `subPath` mount of a `mosquitto.conf` ConfigMap onto `/mosquitto/config/mosquitto.conf` fails with "create target of file bind-mount: ... read-only file system" — the eclipse-mosquitto image has `/mosquitto/config` as read-only. Our values disable the chart's configMap and use the image's built-in default config (anonymous, no persistence).

When you actually deploy MQTT (with auth, TLS, persistence config), use one of:
- An initContainer that copies a config from a ConfigMap to an emptyDir mounted at `/mosquitto/config`
- A custom image extending `eclipse-mosquitto` with your config baked in

## Tear down completely

```bash
helm uninstall mosquitto -n mosquitto
kubectl delete namespace mosquitto
```
