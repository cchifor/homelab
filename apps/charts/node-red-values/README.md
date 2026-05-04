# node-red-values

Status: **chart-only / scaled to 0**. Installed and validated; replicas set to 0.

| | |
|---|---|
| Chart | `k8s-at-home/node-red` (deprecated repo) |
| Pinned version | `10.3.2` (Node-RED 4.0.5) |
| Namespace | `node-red` |
| Exposure | LAN-only via Traefik + LE cert at `https://nodered.chifor.dev` |

## Re-activate

```bash
kubectl -n node-red scale deployment/node-red --replicas=1
```

## Quirk: PVC ownership / EACCES on first install

The `nodered/node-red` image runs as user `node-red` (uid 1000). Longhorn-provisioned PVCs are root-owned by default, so Node-RED's first-launch copy of `settings.js` to `/data` failed with EACCES.

Fix in our values:

```yaml
podSecurityContext:
  fsGroup: 1000
  runAsUser: 1000
  runAsGroup: 1000
```

`fsGroup: 1000` makes the kubelet `chgrp` the PVC to gid 1000 on mount, granting Node-RED's user write access. If you copy this pattern for other apps that run as a non-root uid, the same trick works.

## Note: chart from archived repo

Same caveat as Mosquitto — `k8s-at-home/node-red` won't get updates. Migrate to a maintained chart when you're ready to use Node-RED in earnest.

## Tear down completely

```bash
helm uninstall node-red -n node-red
kubectl delete namespace node-red
```
