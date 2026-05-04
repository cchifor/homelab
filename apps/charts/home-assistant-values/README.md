# home-assistant-values

Status: **chart-only / scaled to 0**. Installed and validated; replicas set to 0 since you don't need it running yet.

| | |
|---|---|
| Chart | `pajikos/home-assistant` (`helm repo add pajikos https://pajikos.github.io/home-assistant-helm-chart`) |
| Pinned version | `0.3.56` (HA 2026.4.4) |
| Namespace | `home-assistant` |
| Exposure | LAN-only via Traefik + LE cert at `https://ha.chifor.dev` |

## Re-activate

```bash
kubectl -n home-assistant scale statefulset/home-assistant --replicas=1
```

PVC + chart values are preserved during scale-to-0; HA picks up where it left off.

## First install (already done; for reference)

```bash
helm upgrade --install home-assistant pajikos/home-assistant \
  --version 0.3.56 \
  -n home-assistant --create-namespace \
  -f apps/charts/home-assistant-values/values.yaml \
  --timeout 8m

kubectl label namespace home-assistant chifor.dev/tier=app --overwrite
```

## Wiring up to Mosquitto + Node-RED later

When you re-activate this trio for actual IoT use:

1. Scale all three back up (HA, Mosquitto, Node-RED)
2. In HA: Settings → Devices & services → Add integration → MQTT → Broker: `mosquitto.mosquitto.svc.cluster.local`, Port: `1883`, anonymous (or set up auth in Mosquitto first)
3. In Node-RED: install `node-red-contrib-home-assistant-websocket` palette → connect to `home-assistant.home-assistant.svc.cluster.local:8123`

## Tear down completely

```bash
helm uninstall home-assistant -n home-assistant
kubectl delete namespace home-assistant
```
