#!/usr/bin/env python3
"""
Uptime Kuma monitor bootstrap for the homelab.

Connects via Socket.IO (uptime-kuma-api), ensures the per-app monitors
listed below exist, and creates whatever's missing. Idempotent — already-
existing monitors are matched by `name` and left alone, so manual UI
tweaks survive subsequent runs.

Usage:
    cd ~/work/home/homelab
    pip install --user uptime-kuma-api
    export UPTIME_KUMA_USERNAME=admin
    export UPTIME_KUMA_PASSWORD='<from Vaultwarden>'
    # If uptime.chifor.dev resolves on this machine (hosts file / LAN DNS):
    export UPTIME_KUMA_URL=https://uptime.chifor.dev
    # …or use a port-forward instead:
    #   kubectl -n uptime-kuma port-forward svc/uptime-kuma 13001:3001 &
    #   export UPTIME_KUMA_URL=http://127.0.0.1:13001
    python apps/scripts/uptime-kuma-bootstrap.py

Environment variables:
    UPTIME_KUMA_URL       (default: https://uptime.chifor.dev)
    UPTIME_KUMA_USERNAME  (default: admin)
    UPTIME_KUMA_PASSWORD  (REQUIRED — read from Vaultwarden)
"""
import os
import sys

try:
    from uptime_kuma_api import UptimeKumaApi, MonitorType
except ImportError:
    sys.exit("ERROR: pip install --user uptime-kuma-api")

URL = os.getenv("UPTIME_KUMA_URL", "https://uptime.chifor.dev")
USERNAME = os.getenv("UPTIME_KUMA_USERNAME", "admin")
PASSWORD = os.getenv("UPTIME_KUMA_PASSWORD")

if not PASSWORD:
    sys.exit("ERROR: UPTIME_KUMA_PASSWORD env var not set")

# === Desired monitors ===
#
# `parent` is the name of a GROUP monitor (auto-created if missing).
# `endpoint` overrides the default "/" probe path. `accepted` lets us
# tolerate redirect codes for apps behind forward-auth (Navidrome) or
# that 302 the root (Vaultwarden /alive is the proper health URL).
#
# HTTP monitors check the URL; PING monitors hit the host with ICMP.
HTTP_MONITORS = [
    # --- Apps (public via Cloudflare Tunnel) ---
    {"group": "Apps",     "name": "Authentik",     "url": "https://authentik.chifor.dev/-/health/ready/"},
    {"group": "Apps",     "name": "ArgoCD",        "url": "https://argocd.chifor.dev/"},
    {"group": "Apps",     "name": "Gitea",         "url": "https://gitea.chifor.dev/"},
    {"group": "Apps",     "name": "Vaultwarden",   "url": "https://vaultwarden.chifor.dev/alive"},
    {"group": "Apps",     "name": "Immich",        "url": "https://immich.chifor.dev/api/server/ping"},
    {"group": "Apps",     "name": "OpenCloud",     "url": "https://cloud.chifor.dev/status.php"},
    {"group": "Apps",     "name": "Paperless-ngx", "url": "https://paperless.chifor.dev/accounts/login/"},
    # CWA: /opds is the bypass path (no Authentik forward-auth) -- responds
    # 401 to anonymous probes, which Uptime Kuma counts as "up" if we set
    # accepted_statuscodes to include 401 below.
    {"group": "Apps",     "name": "Calibre-Web",   "url": "https://books.chifor.dev/opds",
     "accepted": ["200-299", "401"]},
    {"group": "Apps",     "name": "Audiobookshelf","url": "https://audiobooks.chifor.dev/healthcheck"},

    # --- Apps (LAN-only via Traefik + LE) ---
    {"group": "LAN apps", "name": "Homepage",      "url": "https://home.chifor.dev/"},
    {"group": "LAN apps", "name": "Grafana",       "url": "https://grafana.chifor.dev/api/health"},
    # Navidrome's `/` is forward-auth-gated → 302 to Authentik. Hit the
    # Subsonic ping on /rest/ping which bypasses Authentik.
    {"group": "LAN apps", "name": "Navidrome",     "url": "https://music.chifor.dev/rest/ping"},
    {"group": "LAN apps", "name": "Rancher",       "url": "https://rancher.lan/ping"},
    # Chart-only (replicas: 0) — these will be DOWN until you scale them up.
    {"group": "LAN apps", "name": "Home Assistant","url": "https://ha.chifor.dev/"},
    {"group": "LAN apps", "name": "Node-RED",      "url": "https://nodered.chifor.dev/"},
]

PING_MONITORS = [
    {"group": "Infrastructure", "name": "Proxmox host", "host": "192.168.0.185"},
    {"group": "Infrastructure", "name": "NAS LXC (MinIO)", "host": "192.168.0.186"},
    {"group": "Infrastructure", "name": "k3s server",   "host": "192.168.0.187"},
    {"group": "Infrastructure", "name": "OpenClaw LXC", "host": "192.168.0.189"},
    # Workers — unified rdxa1..4 / .131-.134 scheme since 2026-05-19 (the
    # earlier q6a-1..4 / .174/.200/.129/.1.167 layout was renumbered onto the
    # primary .0.0/23 LAN). If you re-run this script and previously had
    # "Worker q6a-*" monitors, delete them via the UI first OR run the
    # companion cleanup snippet at the bottom of this file.
    {"group": "Infrastructure", "name": "Worker rdxa1", "host": "192.168.0.131"},
    {"group": "Infrastructure", "name": "Worker rdxa2", "host": "192.168.0.132"},
    {"group": "Infrastructure", "name": "Worker rdxa3", "host": "192.168.0.133"},
    {"group": "Infrastructure", "name": "Worker rdxa4", "host": "192.168.0.134"},
    # claude-worker VMs running in Incus on each rdxa host (.14N maps to rdxaN).
    {"group": "Infrastructure", "name": "claude-worker-1", "host": "192.168.0.141"},
    {"group": "Infrastructure", "name": "claude-worker-2", "host": "192.168.0.142"},
    {"group": "Infrastructure", "name": "claude-worker-3", "host": "192.168.0.143"},
    {"group": "Infrastructure", "name": "claude-worker-4", "host": "192.168.0.144"},
]

PORT_MONITORS = [
    {"group": "Infrastructure", "name": "MinIO S3",  "host": "192.168.0.186", "port": 9000},
    {"group": "Infrastructure", "name": "k3s API",   "host": "192.168.0.187", "port": 6443},
    # Incus API on each rdxa host (web UI + cluster heartbeat port).
    {"group": "Infrastructure", "name": "Incus rdxa1", "host": "192.168.0.131", "port": 8443},
    {"group": "Infrastructure", "name": "Incus rdxa2", "host": "192.168.0.132", "port": 8443},
    {"group": "Infrastructure", "name": "Incus rdxa3", "host": "192.168.0.133", "port": 8443},
    {"group": "Infrastructure", "name": "Incus rdxa4", "host": "192.168.0.134", "port": 8443},
]

# Stale monitors from the pre-2026-05-19 naming. When the script runs against
# a live Kuma that still has these, delete-by-name first. Idempotent: missing
# names are skipped silently.
STALE_MONITORS = [
    "Worker q6a-1",
    "Worker q6a-2",
    "Worker q6a-3",
    "Worker q6a-4",
]


def main():
    print(f"Connecting to {URL} as {USERNAME!r} …")
    with UptimeKumaApi(URL, wait_events=2) as api:
        api.login(USERNAME, PASSWORD)

        existing = {m["name"]: m for m in api.get_monitors()}
        print(f"  found {len(existing)} existing monitor(s)")

        # 0. Delete stale monitors from the pre-rename scheme. Idempotent —
        # names that don't exist are skipped.
        for name in STALE_MONITORS:
            if name in existing:
                api.delete_monitor(existing[name]["id"])
                print(f"  - removed stale monitor {name!r}")
                del existing[name]

        # 1. Group monitors (parents) — collect the unique set we'll need.
        wanted_groups = sorted({m["group"] for m in HTTP_MONITORS + PING_MONITORS + PORT_MONITORS})
        group_ids: dict = {}
        for g in wanted_groups:
            if g in existing:
                group_ids[g] = existing[g]["id"]
                print(f"  group {g!r} exists (id={group_ids[g]})")
            else:
                r = api.add_monitor(type=MonitorType.GROUP, name=g)
                group_ids[g] = r["monitorID"]
                print(f"  + created group {g!r} (id={group_ids[g]})")

        added = skipped = 0

        # 2. HTTP monitors
        for m in HTTP_MONITORS:
            if m["name"] in existing:
                skipped += 1
                continue
            api.add_monitor(
                type=MonitorType.HTTP,
                name=m["name"],
                url=m["url"],
                parent=group_ids[m["group"]],
                interval=300,
                retryInterval=60,
                maxretries=2,
                accepted_statuscodes=m.get("accepted", ["200-299", "302"]),
                ignoreTls=False,
            )
            print(f"  + HTTP   {m['group']:14s} / {m['name']:18s} -> {m['url']}")
            added += 1

        # 3. PING monitors
        for m in PING_MONITORS:
            if m["name"] in existing:
                skipped += 1
                continue
            api.add_monitor(
                type=MonitorType.PING,
                name=m["name"],
                hostname=m["host"],
                parent=group_ids[m["group"]],
                interval=300,
                retryInterval=60,
                maxretries=2,
            )
            print(f"  + PING   {m['group']:14s} / {m['name']:18s} -> {m['host']}")
            added += 1

        # 4. PORT monitors
        for m in PORT_MONITORS:
            if m["name"] in existing:
                skipped += 1
                continue
            api.add_monitor(
                type=MonitorType.PORT,
                name=m["name"],
                hostname=m["host"],
                port=m["port"],
                parent=group_ids[m["group"]],
                interval=300,
                retryInterval=60,
                maxretries=2,
            )
            print(f"  + PORT   {m['group']:14s} / {m['name']:18s} -> {m['host']}:{m['port']}")
            added += 1

        print(f"\nDONE. added={added} skipped={skipped} total_now={len(existing) + added}")


if __name__ == "__main__":
    main()
