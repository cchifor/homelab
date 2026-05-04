# dns-cleanup

CronJob that reconciles Cloudflare DNS CNAMEs against live `cloudflare-tunnel` Ingresses, deleting orphans the operator left behind on Ingress deletion.

## Why

The `cloudflare-tunnel-ingress-controller` operator removes the tunnel public-hostname rule when an Ingress is deleted, but **leaves the DNS CNAME record orphaned in Cloudflare**. Over time, a homelab that spins apps up and down accumulates a long tail of dead CNAMEs pointing at the tunnel. This CronJob fixes that — every hour it lists live Ingresses, lists tunnel CNAMEs in Cloudflare, and deletes any CNAME without a matching Ingress.

## Deploy

```bash
. platform/.env   # for $TF_VAR_cloudflare_api_token
kubectl apply -f apps/manifests/dns-cleanup/cronjob.yaml
kubectl -n dns-cleanup create secret generic cloudflare-creds \
  --from-literal=api-token="$TF_VAR_cloudflare_api_token" \
  --from-literal=zone-id="<32-char-hex zone id of your domain>"
```

(Zone ID for `chifor.dev` was discovered earlier and is `fcaf7d56ad2c3490af47b68a1c640b4e`. For other domains, find via `curl https://api.cloudflare.com/client/v4/zones?name=<domain>` with the API token.)

## What it does, in detail

1. Reads all `Ingress` resources cluster-wide.
2. Filters to those with `spec.ingressClassName: cloudflare-tunnel` OR annotation `kubernetes.io/ingress.class: cloudflare-tunnel`.
3. Collects the set of `spec.rules[*].host` from those.
4. Calls Cloudflare API to list all CNAME records under the zone.
5. Filters to CNAMEs whose target ends in `.cfargotunnel.com`.
6. Deletes any whose name isn't in the set from step 3.

## RBAC + permissions

- ServiceAccount `dns-cleanup` in namespace `dns-cleanup`
- ClusterRole `dns-cleanup-ingress-reader` granting `list, get` on `networking.k8s.io/ingresses`
- Cloudflare token needs `Zone:DNS:Edit` (already covered by the existing API token used by cert-manager + tunnel operator)

## Run on demand

```bash
kubectl -n dns-cleanup create job --from=cronjob/dns-cleanup manual-run-1
kubectl -n dns-cleanup logs job/manual-run-1
kubectl -n dns-cleanup delete job manual-run-1
```

## Schedule

Hourly (`0 * * * *`). Tune in the CronJob spec.
