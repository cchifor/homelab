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

## Authentik OIDC integration

The Authentik provider + application + k8s Secret were created automatically by `apps/scripts/authentik-oidc-bootstrap.py`. Node-RED's adminAuth lives in `settings.js` (a JS file in the data PVC, not a chart value), so wiring is more involved than the other apps:

1. **Install the OIDC strategy** inside the Node-RED pod (one-time):
   ```bash
   POD=$(kubectl -n node-red get pod -l app.kubernetes.io/name=node-red -o name | head -1)
   kubectl -n node-red exec $POD -- npm --prefix /data install passport-openidconnect
   ```

2. **Edit `/data/settings.js`** — append (or merge into existing `module.exports = { ... }`) an `adminAuth` block:
   ```js
   adminAuth: {
     type: "strategy",
     strategy: {
       name: "openidconnect",
       label: "Sign in with Authentik",
       icon: "fa-cloud",
       strategy: require("passport-openidconnect").Strategy,
       options: {
         issuer:           "https://authentik.chifor.dev/application/o/node-red/",
         authorizationURL: "https://authentik.chifor.dev/application/o/authorize/",
         tokenURL:         "https://authentik.chifor.dev/application/o/token/",
         userInfoURL:      "https://authentik.chifor.dev/application/o/userinfo/",
         clientID:         process.env.OIDC_CLIENT_ID,
         clientSecret:     process.env.OIDC_CLIENT_SECRET,
         callbackURL:      "https://nodered.chifor.dev/auth/strategy/callback",
         scope:            ["openid", "profile", "email"],
         proxy:            true,
         verify:           function(issuer, profile, done) { done(null, profile); },
       },
     },
     users: function(token) {
       return Promise.resolve({ username: token.username || token, permissions: "*" });
     },
   },
   ```

3. **Project the Secret as env vars** so settings.js can read them:
   ```bash
   kubectl -n node-red set env deploy/node-red \
     --from=secret/authentik-oidc \
     --keys=client-id,client-secret \
     --prefix=OIDC_
   # Result: OIDC_CLIENT-ID + OIDC_CLIENT-SECRET (note dash, not underscore —
   # rename to OIDC_CLIENT_ID/SECRET in settings.js if you prefer underscores).
   ```

4. **Restart the pod** so Node-RED reloads settings.js:
   ```bash
   kubectl -n node-red rollout restart deploy/node-red
   ```

The login page at `https://nodered.chifor.dev` now shows the "Sign in with Authentik" button. **Caveat:** anyone who completes the OIDC flow gets full editor permissions (`'*'`). Tighten the `users()` function with allowlist logic or a group claim check if Node-RED ever moves off chart-only status.

## Tear down completely

```bash
helm uninstall node-red -n node-red
kubectl delete namespace node-red
```
