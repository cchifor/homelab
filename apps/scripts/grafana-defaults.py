#!/usr/bin/env python3
"""
Grafana org-level defaults bootstrap.

The kube-prometheus-stack chart provisions dashboards but does NOT set the
org default home dashboard or other per-org preferences -- those live in
Grafana's database (preference table), which survives chart upgrades but
gets wiped if the underlying PV is destroyed. Run this any time you
reinstall Grafana from scratch (or after the very first install) to put
the right defaults back.

Currently sets:
  - org-level home dashboard  → uid: homelab_overview
                                 (the apps/manifests/grafana-dashboards/
                                  homelab-overview.json landing page)

Idempotent -- re-runs are no-ops if the desired state is already in place.

Usage:
    cd ~/work/home/homelab
    . apps/charts/kube-prometheus-stack-values/.secrets.env
    # Either resolve grafana.chifor.dev locally:
    export GRAFANA_URL=https://grafana.chifor.dev
    # …or port-forward:
    #   kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 13030:80 &
    #   export GRAFANA_URL=http://127.0.0.1:13030
    python apps/scripts/grafana-defaults.py

Environment:
    GRAFANA_URL              (default: https://grafana.chifor.dev)
    GRAFANA_ADMIN_USER       (default: admin)
    GRAFANA_ADMIN_PASSWORD   (REQUIRED -- sourced from .secrets.env)

If auth fails: kube-prometheus-stack only honours grafana.adminPassword
at FIRST install, so the helm-values password can drift from what's
actually in Grafana's DB. Reset it back via:

    POD=$(kubectl -n monitoring get pod \\
      -l app.kubernetes.io/name=grafana,app.kubernetes.io/instance=kube-prometheus-stack \\
      -o jsonpath='{.items[0].metadata.name}')
    kubectl -n monitoring exec $POD -c grafana -- \\
      /usr/share/grafana/bin/grafana cli --homepath=/usr/share/grafana \\
      admin reset-admin-password "$GRAFANA_ADMIN_PASSWORD"
    kubectl -n monitoring rollout restart deploy/kube-prometheus-stack-grafana
"""
import base64
import json
import os
import sys
import urllib.error
import urllib.request


GRAFANA_URL = os.getenv("GRAFANA_URL", "https://grafana.chifor.dev").rstrip("/")
USER = os.getenv("GRAFANA_ADMIN_USER", "admin")
PASSWORD = os.getenv("GRAFANA_ADMIN_PASSWORD")

# === Desired state ===
HOME_DASHBOARD_UID = "homelab_overview"


def _basic_auth() -> str:
    return "Basic " + base64.b64encode(f"{USER}:{PASSWORD}".encode()).decode()


def api(path: str, method: str = "GET", body: dict | None = None) -> dict:
    url = f"{GRAFANA_URL}/api{path}"
    data = json.dumps(body).encode() if body else None
    req = urllib.request.Request(
        url, data=data, method=method,
        headers={
            "Authorization": _basic_auth(),
            "Content-Type": "application/json",
            "Accept": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            txt = r.read().decode()
            return json.loads(txt) if txt else {}
    except urllib.error.HTTPError as e:
        body = e.read().decode()
        if e.code == 401:
            sys.exit(
                f"ERROR: 401 from Grafana -- admin password mismatch.\n"
                f"See header of this script for the grafana-cli reset incantation.\n"
                f"Response: {body[:200]}"
            )
        sys.exit(f"ERROR: {method} {url} -> HTTP {e.code}\n{body[:300]}")
    except urllib.error.URLError as e:
        sys.exit(f"ERROR: cannot reach {url}: {e.reason}")


def ensure_home_dashboard():
    """Org default home dashboard → HOME_DASHBOARD_UID (if not already)."""
    print(f"==> Org default home dashboard")

    # Confirm the target dashboard actually exists; otherwise the preference
    # silently fails and users land on the generic "Welcome to Grafana".
    try:
        api(f"/dashboards/uid/{HOME_DASHBOARD_UID}")
    except SystemExit:
        sys.exit(
            f"ERROR: dashboard uid {HOME_DASHBOARD_UID!r} not found in Grafana.\n"
            f"Apply the dashboard ConfigMaps first:\n"
            f"  kubectl apply -k apps/manifests/grafana-dashboards/"
        )

    current = api("/org/preferences")
    if current.get("homeDashboardUID") == HOME_DASHBOARD_UID:
        print(f"  already set to {HOME_DASHBOARD_UID!r} -- skip")
        return

    # PATCH lets us update only the keys we care about; PUT replaces the
    # whole document and would clobber any theme/timezone the operator set
    # via the UI.
    api("/org/preferences", method="PATCH",
        body={"homeDashboardUID": HOME_DASHBOARD_UID})
    print(f"  set homeDashboardUID = {HOME_DASHBOARD_UID!r}")


def main():
    if not PASSWORD:
        sys.exit("ERROR: GRAFANA_ADMIN_PASSWORD not set -- source the chart's "
                 ".secrets.env first")

    print(f"Grafana defaults at {GRAFANA_URL} (user={USER!r})")
    health = api("/health")
    print(f"  version={health.get('version')}  database={health.get('database')}")

    ensure_home_dashboard()

    print("\nDONE.")


if __name__ == "__main__":
    main()
