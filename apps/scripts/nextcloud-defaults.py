#!/usr/bin/env python3
"""
Nextcloud post-install defaults bootstrap.

The chart provisions the deployment + DB but doesn't touch Nextcloud's
app catalogue or org-level config. Run this any time you reinstall (or
after the first install) to:

  1. Install + register `user_oidc` against the Authentik provider that
     `apps/scripts/authentik-oidc-bootstrap.py` created. (Mapping-uid =
     preferred_username so Authentik usernames become Nextcloud usernames.
     Auto-provisions on first OIDC sign-in.)
  2. Disable Nextcloud apps unrelated to file management so the UI is
     focused on Files (Activity, Comments, Photos, Dashboard, Federation,
     etc.). Files-related, auth/security, and admin apps stay on.
  3. Set `defaultapp=files` so login lands on the file list (not the
     generic dashboard widget page).

Idempotent: re-runs are no-ops for already-disabled apps and existing
provider config. Doesn't touch apps NOT in DISABLE_APPS, so anything you
hand-enable via the UI later survives.

Usage (operator machine, with kubectl context on the cluster):
    cd ~/work/home/homelab
    python apps/scripts/nextcloud-defaults.py

The script shells out to `kubectl -n nextcloud exec deploy/nextcloud --
occ ...` -- no credentials required (occ runs unauth-priv inside the pod).

Environment overrides (rarely needed):
    NC_NAMESPACE   (default: nextcloud)
    NC_DEPLOY      (default: nextcloud)
    NC_OIDC_PROVIDER_NAME  (default: Authentik)
    NC_OIDC_DISCOVERY_URL  (default: https://authentik.chifor.dev/application/o/nextcloud/.well-known/openid-configuration)
"""
import os
import subprocess
import sys


NC_NS         = os.getenv("NC_NAMESPACE", "nextcloud")
NC_DEPLOY     = os.getenv("NC_DEPLOY",    "nextcloud")
PROV_NAME     = os.getenv("NC_OIDC_PROVIDER_NAME", "Authentik")
DISCOVERY_URL = os.getenv(
    "NC_OIDC_DISCOVERY_URL",
    "https://authentik.chifor.dev/application/o/nextcloud/.well-known/openid-configuration",
)

# Apps to DISABLE -- everything not directly file-management or
# auth/security/admin. The list intentionally errs on the side of
# disabling things; re-enable any you actually want via the UI.
#
# NB: `activity` IS kept enabled -- the activity stream is the file
# audit log we actually want for "what happened in my files lately".
DISABLE_APPS = [
    "circles",
    "comments",
    "contactsinteraction",
    "dashboard",
    "federation",
    "nextcloud_announcements",
    "photos",
    "privacy",
    "recommendations",
    "related_resources",
    "support",
    "survey_client",
    "weather_status",
    "webhook_listeners",
]

# Apps that occ refuses to disable -- Nextcloud ships them as required:
#   cloud_federation_api, federatedfilesharing, lookup_server_connector


def occ(*args: str, ok_phrases: tuple = ()) -> str:
    """Run `occ <args>` inside the nextcloud pod; return stdout.

    Some occ subcommands (notably app:install) return non-zero on harmless
    states like "already installed". Pass those substrings via ok_phrases
    and we'll treat them as success.
    """
    cmd = [
        "kubectl", "-n", NC_NS, "exec", f"deploy/{NC_DEPLOY}", "-c", "nextcloud",
        "--", "su", "-s", "/bin/bash", "www-data", "-c",
        "php /var/www/html/occ " + " ".join(_quote(a) for a in args),
    ]
    r = subprocess.run(cmd, capture_output=True, text=True)
    out = (r.stdout or "") + (r.stderr or "")
    if r.returncode != 0:
        if any(p in out for p in ok_phrases):
            return r.stdout
        sys.stderr.write(f"ERROR: occ {args} -> exit {r.returncode}\n{out}\n")
        sys.exit(1)
    return r.stdout


def _quote(s: str) -> str:
    return "'" + s.replace("'", "'\\''") + "'"


def get_secret(key: str) -> str:
    """Decode a base64 value from the authentik-oidc Secret in the nextcloud ns."""
    r = subprocess.run(
        ["kubectl", "-n", NC_NS, "get", "secret", "authentik-oidc",
         "-o", f"jsonpath={{.data.{key}}}"],
        capture_output=True, text=True,
    )
    if r.returncode != 0 or not r.stdout:
        sys.exit(f"ERROR: secret authentik-oidc/{key} not found in ns {NC_NS!r}.\n"
                 f"Run apps/scripts/authentik-oidc-bootstrap.py first.")
    import base64
    return base64.b64decode(r.stdout).decode()


def ensure_oidc_provider():
    print("==> user_oidc app + Authentik provider")

    # 1. Install user_oidc (occ exits 1 if already-installed; tolerate)
    occ("app:install", "user_oidc", ok_phrases=("already installed",))
    # Enable is separately idempotent (returns 0 even if already enabled)
    occ("app:enable", "user_oidc", ok_phrases=("already enabled",))

    cid = get_secret("client-id")
    csec = get_secret("client-secret")

    # 2. Check current provider config. user_oidc:provider lists providers
    # in a table; the identifier column tells us if our PROV_NAME exists.
    listing = occ("user_oidc:provider")
    name_exists = any(line.startswith("|") and PROV_NAME in line
                      for line in listing.splitlines())

    # Always (re-)register: idempotent on the identifier and we can't
    # cheaply diff client_id/secret from the listing. Subsequent runs
    # are fast.
    occ("user_oidc:provider", PROV_NAME,
        "--clientid", cid,
        "--clientsecret", csec,
        "--discoveryuri", DISCOVERY_URL,
        "--scope", "openid email profile",
        "--mapping-uid", "preferred_username",
        "--mapping-display-name", "name",
        "--mapping-email", "email",
        "--unique-uid", "0")
    occ("config:app:set", "user_oidc", "auto_provision", "--value=1")
    state = "updated" if name_exists else "created"
    print(f"   provider {PROV_NAME!r} {state} (client_id={cid[:8]}...)")


def disable_unwanted_apps():
    print("==> disable non-file apps")
    listing = occ("app:list", "--output=json")
    import json as _json
    state = _json.loads(listing)
    enabled = state.get("enabled", {})

    disabled = skipped = refused = 0
    for app in DISABLE_APPS:
        if app not in enabled:
            skipped += 1
            continue
        out = occ("app:disable", app)
        line = out.strip().splitlines()[-1] if out.strip() else ""
        if "can't be disabled" in line.lower():
            refused += 1
        else:
            disabled += 1
        print(f"   {line}")

    print(f"  ({disabled} disabled, {skipped} already off, {refused} refused by Nextcloud)")


def ensure_default_landing_page():
    print("==> defaultapp = files (login lands on file list, not dashboard)")
    out = occ("config:system:get", "defaultapp")
    current = out.strip()
    if current == "files":
        print(f"   already set to {current!r} -- skip")
        return
    occ("config:system:set", "defaultapp", "--value=files")
    print(f"   set defaultapp: {current!r} -> 'files'")


def main():
    print(f"Nextcloud post-install defaults (ns={NC_NS!r}, deploy={NC_DEPLOY!r})")
    ensure_oidc_provider()
    disable_unwanted_apps()
    ensure_default_landing_page()
    print("\nDONE.")


if __name__ == "__main__":
    main()
