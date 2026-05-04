# argocd-values

GitOps controller — `git push` deploys, `git revert` rolls back, `git log` is the audit trail.

| | |
|---|---|
| Chart | `argo/argo-cd` (`helm repo add argo https://argoproj.github.io/argo-helm`) |
| Pinned version | `9.5.11` (Argo CD v3.3.9) |
| Namespace | `argocd` |
| Exposure | **Public via Cloudflare Tunnel** |
| URL | https://argocd.chifor.dev |

## Install

```bash
helm upgrade --install argocd argo/argo-cd \
  --version 9.5.11 \
  -n argocd --create-namespace \
  -f apps/charts/argocd-values/values.yaml \
  --timeout 10m

kubectl label namespace argocd chifor.dev/tier=platform --overwrite
```

## First login

- URL: https://argocd.chifor.dev
- Username: `admin`
- Password: chart auto-generates one. Read it:
  ```bash
  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
  ```
  Saved at install time to `.secrets.env` as `ARGOCD_ADMIN_PASSWORD`. **Change via UI on first login**, then delete the bootstrap secret:
  ```bash
  kubectl -n argocd delete secret argocd-initial-admin-secret
  ```

## Wire up the apps-of-apps root (one-time, after first login)

The git repo `cchifor/homelab` is private. ArgoCD needs auth to read it. Two options:

### Option A: HTTPS + GitHub Personal Access Token (simpler)

1. Create a fine-grained GitHub PAT scoped to the `cchifor/homelab` repo with **Contents: Read** permission. https://github.com/settings/personal-access-tokens
2. Apply the credentials Secret:
   ```bash
   kubectl apply -f - <<EOF
   apiVersion: v1
   kind: Secret
   metadata:
     name: homelab-repo
     namespace: argocd
     labels:
       argocd.argoproj.io/secret-type: repository
   stringData:
     type: git
     url: https://github.com/cchifor/homelab
     username: cchifor
     password: <your-pat>
   EOF
   ```
3. Update `apps/argocd-apps/root.yaml` to use HTTPS URL:
   ```yaml
   repoURL: https://github.com/cchifor/homelab
   ```
4. Apply the root Application:
   ```bash
   kubectl apply -f apps/argocd-apps/root.yaml
   ```

### Option B: SSH + Deploy Key (more secure)

1. Generate a dedicated SSH keypair for ArgoCD:
   ```bash
   ssh-keygen -t ed25519 -f ~/.ssh/argocd-homelab -C argocd-homelab -N ""
   ```
2. Add the **public** key (`~/.ssh/argocd-homelab.pub`) as a Deploy Key in GitHub: repo Settings → Deploy keys → Add (read-only)
3. Apply the credentials Secret with the **private** key:
   ```bash
   kubectl create secret generic homelab-repo \
     -n argocd \
     --from-file=sshPrivateKey=$HOME/.ssh/argocd-homelab \
     --from-literal=type=git \
     --from-literal=url=git@github.com:cchifor/homelab \
     --dry-run=client -o yaml | \
     kubectl label --local -f - --dry-run=client -o yaml argocd.argoproj.io/secret-type=repository | \
     kubectl apply -f -
   ```
4. The default `apps/argocd-apps/root.yaml` already uses `git@github.com:cchifor/homelab.git` — apply it directly:
   ```bash
   kubectl apply -f apps/argocd-apps/root.yaml
   ```

## What happens after `kubectl apply -f apps/argocd-apps/root.yaml`

ArgoCD's controller starts watching `apps/argocd-apps/` in the repo. Any `*.yaml` file in there (other than `root.yaml` and `README.md`, which are excluded) becomes a managed Application. Currently the directory is empty except for the root file — so nothing auto-deploys yet. Adding `apps/argocd-apps/<app>.yaml` and pushing will deploy that app.

## Migrating existing helm-installed apps to ArgoCD

The 11 apps already running (cert-manager, longhorn, rancher, monitoring, velero, cloudflared-ingress, vaultwarden, gitea, uptime-kuma, homepage, nextcloud, paperless, authentik) were installed via direct `helm install` and ArgoCD doesn't know about them. The migration pattern per app:

```bash
# 1. helm uninstall — drops Helm-managed labels but PVCs survive (Longhorn keeps the PV)
helm uninstall <app> -n <namespace>

# 2. add Application manifest in apps/argocd-apps/, push
git add apps/argocd-apps/<app>.yaml && git commit -m 'argocd: migrate <app>' && git push

# 3. Argo CD picks it up via the apps-of-apps root and reinstalls.
#    PVC re-binds to the existing PV (same name, same namespace = Longhorn reuses).
```

Brief downtime per app (~30-60s) during the helm uninstall → ArgoCD recreate. Migrate apps you'd reinstall anyway (e.g., during a chart upgrade) and let the others stay helm-managed for now.

## Authentik OIDC integration

Already wired in `values.yaml` (`configs.cm.oidc.config`). The provider + application are created in Authentik by `apps/scripts/authentik-oidc-bootstrap.py`, which also writes a Secret `authentik-oidc` in the `argocd` namespace with `client-id`, `client-secret`, and `issuer-url` keys.

ArgoCD's `$<secret-name>:<key>` substitution mechanism (used in `values.yaml` for `clientID` / `clientSecret`) **only reads from Secrets carrying the label `app.kubernetes.io/part-of: argocd`**. Without the label, ArgoCD passes the placeholder string through as the OAuth client_id, Authentik rejects the login with an "invalid client" error, and the only signal in `argocd-server` logs is:

```
config referenced '$authentik-oidc:client-id', but key does not exist in secret
```

(misleading — the keys *do* exist; the secret is invisible to ArgoCD because of the missing label).

The bootstrap script now sets the label automatically. If you ever recreate the Secret out-of-band, ensure the label is present:

```bash
kubectl -n argocd label secret authentik-oidc app.kubernetes.io/part-of=argocd --overwrite
kubectl -n argocd rollout restart deploy/argocd-server
```

## Uninstall

```bash
helm uninstall argocd -n argocd
kubectl delete namespace argocd   # cleans up CRDs + Application resources
```

Note: deleting the argocd namespace ALSO deletes every ArgoCD Application's managed resources (chart releases). Migrate apps off ArgoCD before uninstalling.
