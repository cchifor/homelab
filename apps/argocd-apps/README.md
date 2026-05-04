# argocd-apps/

ArgoCD Application manifests — one YAML per app. Each Application points at a chart in `apps/charts/<name>-values/` and tells ArgoCD to keep the cluster in sync with what's in git.

## Conventions

- One file per Application: `<app-name>.yaml`
- Each Application points at the same `apps/charts/<name>-values/values.yaml` already in use for direct `helm install`
- `targetNamespace` matches the conventional per-app namespace (e.g., `vaultwarden`, `gitea`)
- `syncPolicy.automated` is set so ArgoCD self-heals drift
- Secrets (DB passwords, admin tokens) come from a per-namespace `kubernetes_secret` you manage out-of-band — NOT committed inline

## Apps-of-apps root

`root.yaml` is a single Application that watches THIS directory. Apply it once, ArgoCD picks up every other YAML in here automatically — adding a new app is just adding a new file.

## Migrating an existing helm release to ArgoCD

For apps already installed via direct `helm install` (everything from phases 1-3), the migration path is:

```bash
# 1. helm uninstall — this removes the Helm-managed labels but leaves PVCs intact
helm uninstall <app> -n <namespace>

# 2. wait for resources to fully disappear (~30s)
kubectl -n <namespace> get all

# 3. add the Application manifest in this directory + commit
git add apps/argocd-apps/<app>.yaml && git commit && git push

# 4. ArgoCD picks it up via the apps-of-apps root and reinstalls from chart values.
#    PVC re-binding is automatic (Longhorn keeps the volume around when PVC is
#    deleted-and-recreated by name in the same namespace — the chart's PVC
#    template will reuse the existing PV).
```

Brief downtime per app (~30-60s) during the helm uninstall → ArgoCD recreate.

For NEW apps going forward, skip the helm install entirely — just create the Application here and let ArgoCD do everything from the start.

## Why git as source of truth

- `git push` deploys
- `git revert` rolls back
- `git log` is your audit trail
- ArgoCD reconciles every 3 minutes (or on git webhook), correcting drift caused by `kubectl edit`-ing in panic during incidents
