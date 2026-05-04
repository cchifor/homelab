# velero-values

Upstream-chart-with-our-values pattern for [Velero](https://velero.io/) — k8s-native backup/restore. Backups go to the cluster's MinIO LXC.

| | |
|---|---|
| Chart | `vmware-tanzu/velero` (`helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts`) |
| Pinned version | `12.0.1` |
| Namespace | `velero` |
| Exposure | None (no UI; CLI / kubectl only) |
| Backend | MinIO (192.168.0.186:9000), bucket `velero` |
| Default schedule | `0 3 * * *` (daily 03:00, 30-day TTL, all namespaces except kube-*) |

## Pre-install setup (one-time)

The chart needs a Secret with MinIO credentials and a pre-created `velero` bucket in MinIO. Both are platform-level resources, recreated identically per environment:

```bash
# 1. Create the velero bucket via an in-cluster mc Job (no need for mc on the operator host)
MINIO_ROOT_PASSWORD=$(cd platform && terraform output -raw minio_root_password)
MSYS_NO_PATHCONV=1 kubectl run mc-create-velero \
  --image=minio/mc:latest --restart=Never --rm -i \
  --command -- /bin/sh -c "mc alias set local http://192.168.0.186:9000 admin $MINIO_ROOT_PASSWORD && mc mb --ignore-existing local/velero"

# 2. Create the velero namespace + Secret
kubectl create namespace velero --dry-run=client -o yaml | kubectl apply -f -
kubectl -n velero create secret generic velero-minio-creds \
  --from-literal=cloud="[default]
aws_access_key_id=admin
aws_secret_access_key=$MINIO_ROOT_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -
```

## Install

```bash
helm upgrade --install velero vmware-tanzu/velero \
  --version 12.0.1 \
  -n velero --create-namespace \
  -f apps/charts/velero-values/values.yaml \
  --timeout 5m
```

## Daily ops

```bash
# List recent backups
kubectl -n velero get backups.velero.io

# Trigger an ad-hoc backup of one namespace
cat <<EOF | kubectl create -f -
apiVersion: velero.io/v1
kind: Backup
metadata:
  name: my-backup
  namespace: velero
spec:
  includedNamespaces: [<namespace>]
  ttl: "168h"   # 7 days
  storageLocation: default
EOF

# Restore from a backup
cat <<EOF | kubectl create -f -
apiVersion: velero.io/v1
kind: Restore
metadata:
  name: my-restore
  namespace: velero
spec:
  backupName: my-backup
  includedNamespaces: [<namespace>]
EOF

kubectl -n velero get restores.velero.io my-restore -w
```

## What's actually backed up

Velero captures **k8s API resources** (Deployments, Services, Secrets, ConfigMaps, PVCs+PVs metadata, Ingresses, etc.) and stores them as a tarball in MinIO. It does **not** back up the contents of PVs by default — that's `defaultVolumesToFsBackup: false` in our values.

For app data persistence (the actual bytes inside Longhorn volumes), the platform's Longhorn `BackupTarget` to MinIO covers it — Longhorn snapshots+backups are managed separately in the Longhorn UI.

So the split is:
- **Velero** → cluster-level "if I helm uninstall my mistake, I can restore the resources"
- **Longhorn backups** → "if a worker dies, the volume data lives on in MinIO"

## Daily schedule

The chart values define a single Schedule (`velero-daily-cluster`) that backs up all non-system namespaces nightly:

```bash
kubectl -n velero get schedules.velero.io
# velero-daily-cluster   Enabled   0 3 * * *
```

Inspect what it last did:

```bash
kubectl -n velero get backups.velero.io -l velero.io/schedule-name=velero-daily-cluster
```

## Uninstall

```bash
helm uninstall velero -n velero
kubectl delete namespace velero    # CRDs + remaining resources

# Optional: clean MinIO bucket (or keep for offline restore)
# mc rb --force local/velero
```
