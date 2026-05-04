# nextcloud-values

Self-hosted file sync, calendar, contacts, and more.

| | |
|---|---|
| Chart | `nextcloud/nextcloud` (`helm repo add nextcloud https://nextcloud.github.io/helm/`) |
| Pinned version | `9.0.6` (Nextcloud 33.0.3) |
| Namespace | `nextcloud` |
| Exposure | **Public via Cloudflare Tunnel** |
| URL | https://nextcloud.chifor.dev |
| Storage | 50 GiB Longhorn (data) + 10 GiB Longhorn (mariadb) |

## Install

```bash
cd ~/work/home/homelab
. apps/charts/nextcloud-values/.secrets.env

helm upgrade --install nextcloud nextcloud/nextcloud \
  --version 9.0.6 \
  -n nextcloud --create-namespace \
  -f apps/charts/nextcloud-values/values.yaml \
  --set "nextcloud.password=$NEXTCLOUD_ADMIN_PASSWORD" \
  --set "mariadb.auth.password=$NEXTCLOUD_DB_PASSWORD" \
  --set "mariadb.auth.rootPassword=$NEXTCLOUD_DB_ROOT_PASSWORD" \
  --timeout 10m
```

## First login

- URL: https://nextcloud.chifor.dev
- Username: `admin`
- Password: `$NEXTCLOUD_ADMIN_PASSWORD` from `.secrets.env`

Change admin password via Settings → Personal → Security after first login.

## Reverse-proxy / tunnel notes

The `nextcloud.configs.proxy.config.php` value sets:
- `overwriteprotocol: https` — Nextcloud generates `https://` links even though it sees plain HTTP from cloudflared
- `overwritehost: nextcloud.chifor.dev` — generated URLs use the public hostname, not the cluster service name
- `trusted_proxies: 10.42.0.0/16` — k3s default pod CIDR; tells Nextcloud the X-Forwarded-* headers from cloudflared are trustworthy

Without these, the WebDAV mobile sync clients break (mismatched scheme/host between `Location` headers and the URL the client used).

## Mobile + desktop client setup

In any Nextcloud client (mobile / desktop), the server URL is `https://nextcloud.chifor.dev`. Username + password as above. CalDAV/CardDAV clients use `https://nextcloud.chifor.dev/remote.php/dav`.

## Uninstall

```bash
helm uninstall nextcloud -n nextcloud
kubectl delete namespace nextcloud   # PVCs deleted (data + mariadb + redis)
# Manually delete CF DNS CNAME for nextcloud.chifor.dev (operator orphans it).
```
