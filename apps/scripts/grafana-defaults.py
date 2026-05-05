#!/usr/bin/env python3
"""
Grafana org-level defaults bootstrap.

The kube-prometheus-stack chart provisions dashboards but does NOT set the
org default home dashboard or other per-org preferences -- those live in
Grafana's database (preference table), which survives chart upgrades but
gets wiped if the underlying PV is destroyed. Run this any time you
reinstall Grafana from scratch (or after the very first install) to put
the right defaults back.

Currently sets these /api/org/preferences keys (each overridable via env):
  - homeDashboardUID  (default "homelab_overview")
  - theme             (default "dark")
  - timezone          (default "browser")
  - weekStart         (default "monday")

Idempotent: re-runs PATCH only the keys that drift; manual UI tweaks to
keys NOT listed above (e.g. queryHistory.homeTab, language) are preserved.

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
    GRAFANA_URL                  (default: https://grafana.chifor.dev)
    GRAFANA_ADMIN_USER           (default: admin)
    GRAFANA_ADMIN_PASSWORD       (REQUIRED -- sourced from .secrets.env)
    GRAFANA_HOME_DASHBOARD_UID   (default: homelab_overview)
    GRAFANA_THEME                (default: dark        | light | system)
    GRAFANA_TIMEZONE             (default: browser     | utc   | <IANA tz>)
    GRAFANA_WEEK_START           (default: monday      | sunday | saturday | "")

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
# Each of these is overridable via env var (per the docstring) so a future
# operator can flip the default without editing the script.
HOME_DASHBOARD_UID = os.getenv("GRAFANA_HOME_DASHBOARD_UID", "homelab_overview")
THEME              = os.getenv("GRAFANA_THEME",      "dark")    # dark | light | system
TIMEZONE           = os.getenv("GRAFANA_TIMEZONE",   "browser") # browser | utc | <IANA>
WEEK_START         = os.getenv("GRAFANA_WEEK_START", "monday")  # monday | sunday | saturday | "" (default)


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


def ensure_org_preferences():
    """Set org-level Grafana preferences -- home dashboard, theme, timezone,
    week start. Idempotent: PATCHes only the keys whose current value differs
    from the desired value, so manual UI tweaks to OTHER keys are preserved.
    """
    print("==> Org preferences")

    # Confirm the target dashboard actually exists; otherwise the preference
    # silently fails and users land on the generic "Welcome to Grafana".
    if HOME_DASHBOARD_UID:
        try:
            api(f"/dashboards/uid/{HOME_DASHBOARD_UID}")
        except SystemExit:
            sys.exit(
                f"ERROR: dashboard uid {HOME_DASHBOARD_UID!r} not found in Grafana.\n"
                f"Apply the dashboard ConfigMaps first:\n"
                f"  kubectl apply -k apps/manifests/grafana-dashboards/"
            )

    desired = {
        "homeDashboardUID": HOME_DASHBOARD_UID,
        "theme":            THEME,
        "timezone":         TIMEZONE,
        "weekStart":        WEEK_START,
    }
    # Drop empty-string values (treat as "no preference"; don't PATCH them).
    desired = {k: v for k, v in desired.items() if v != ""}

    current = api("/org/preferences")
    drift = {k: v for k, v in desired.items() if current.get(k) != v}

    if not drift:
        print(f"  all desired keys match current -- skip")
        for k, v in desired.items():
            print(f"    {k:18s} = {v!r}")
        return

    api("/org/preferences", method="PATCH", body=drift)
    for k, v in drift.items():
        old = current.get(k, "<unset>")
        print(f"  set {k:18s} {old!r:>25s}  ->  {v!r}")
    # Print the unchanged ones too so the operator sees the full effective state.
    for k, v in desired.items():
        if k not in drift:
            print(f"  ok  {k:18s} = {v!r}")


def main():
    if not PASSWORD:
        sys.exit("ERROR: GRAFANA_ADMIN_PASSWORD not set -- source the chart's "
                 ".secrets.env first")

    print(f"Grafana defaults at {GRAFANA_URL} (user={USER!r})")
    health = api("/health")
    print(f"  version={health.get('version')}  database={health.get('database')}")

    ensure_org_preferences()

    print("\nDONE.")


if __name__ == "__main__":
    main()
