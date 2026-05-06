#!/usr/bin/env python3
"""
Audiobookshelf post-install defaults bootstrap.

The chart provisions the deployment but ABS persists user + auth config in
its SQLite on first init. There's no chart-side way to set the initial
admin or wire OpenID Connect. This script does both, idempotently.

Behavior:
  - first-time (status.isInit == false):
        POST /init  -> create admin with chosen username/password
        POST /login -> session token
        PATCH /api/auth-settings -> wire Authentik OIDC from the
            authentik-oidc Secret in the namespace
  - already initialized + supplied admin password works:
        POST /login + reconcile OIDC fields if drifted
  - already initialized + password rejected:
        bail with a clear message; operator can either supply the right
        password via env, or wipe ABS's `/config` PVC + re-run

Usage:
    cd ~/work/home/homelab
    # first run -- generates a random admin password and prints it at the end:
    python apps/scripts/audiobookshelf-defaults.py

    # explicit password (e.g. you want a stable known one across reinstalls):
    AUDIOBOOKSHELF_ADMIN_PASSWORD='your-pass' \
      python apps/scripts/audiobookshelf-defaults.py

Environment overrides:
    AUDIOBOOKSHELF_NAMESPACE        (default: audiobookshelf)
    AUDIOBOOKSHELF_DEPLOY           (default: audiobookshelf)
    AUDIOBOOKSHELF_PUBLIC_URL       (default: https://audiobooks.chifor.dev)
    AUDIOBOOKSHELF_ADMIN_USER       (default: admin)
    AUDIOBOOKSHELF_ADMIN_PASSWORD   (default: random 24 chars)

Stdlib-only Python; shells out to kubectl for Secret reads.
"""
import base64
import json
import os
import secrets
import string
import subprocess
import sys
import urllib.error
import urllib.request


NAMESPACE  = os.getenv("AUDIOBOOKSHELF_NAMESPACE", "audiobookshelf")
DEPLOY     = os.getenv("AUDIOBOOKSHELF_DEPLOY",    "audiobookshelf")
PUBLIC_URL = os.getenv("AUDIOBOOKSHELF_PUBLIC_URL", "https://audiobooks.chifor.dev").rstrip("/")
ADMIN_USER = os.getenv("AUDIOBOOKSHELF_ADMIN_USER", "admin")
ADMIN_PASS = os.getenv("AUDIOBOOKSHELF_ADMIN_PASSWORD")

# Cloudflare Bot Fight Mode rejects Python-urllib's default UA with HTTP 403.
UA = "audiobookshelf-defaults/1.0"


def kubectl_secret(key: str) -> str:
    r = subprocess.run(
        ["kubectl", "-n", NAMESPACE, "get", "secret", "authentik-oidc",
         "-o", f"jsonpath={{.data.{key}}}"],
        capture_output=True, text=True,
    )
    if r.returncode != 0 or not r.stdout:
        sys.exit(
            f"ERROR: secret authentik-oidc/{key} not found in ns {NAMESPACE!r}.\n"
            f"Run apps/scripts/authentik-oidc-bootstrap.py first to create it."
        )
    return base64.b64decode(r.stdout).decode()


def http(method: str, path: str, body: dict | None = None,
         token: str | None = None, expect_json: bool = True) -> dict:
    url = f"{PUBLIC_URL}{path}"
    data = json.dumps(body).encode() if body is not None else None
    headers = {"User-Agent": UA, "Accept": "application/json"}
    if data is not None:
        headers["Content-Type"] = "application/json"
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            txt = r.read().decode()
            if not expect_json or not txt:
                return {}
            return json.loads(txt)
    except urllib.error.HTTPError as e:
        body_txt = e.read().decode()
        sys.exit(f"ERROR: {method} {url} -> HTTP {e.code}\n{body_txt[:300]}")
    except urllib.error.URLError as e:
        sys.exit(f"ERROR: cannot reach {url}: {e.reason}")


def status() -> dict:
    return http("GET", "/status")


def init_admin(user: str, password: str) -> None:
    print(f"  POST /init -- creating initial admin {user!r}")
    http("POST", "/init", body={
        "newRoot": {"username": user, "password": password, "type": "root"},
    }, expect_json=False)


def login(user: str, password: str) -> str:
    r = http("POST", "/login", body={"username": user, "password": password})
    user_obj = r.get("user") or {}
    token = user_obj.get("token")
    if not token:
        sys.exit(f"ERROR: /login response missing token: {r}")
    return token


def configure_oidc(token: str, oidc: dict) -> None:
    """PATCH /api/auth-settings with Authentik OIDC fields. Only fields that
    differ from current state get sent so the script doesn't churn the DB."""
    issuer = oidc["issuer"].rstrip("/")
    desired = {
        "authActiveAuthMethods":           ["local", "openid"],
        "authOpenIDIssuerURL":             issuer + "/",
        "authOpenIDAuthorizationURL":      "https://authentik.chifor.dev/application/o/authorize/",
        "authOpenIDTokenURL":              "https://authentik.chifor.dev/application/o/token/",
        "authOpenIDUserInfoURL":           "https://authentik.chifor.dev/application/o/userinfo/",
        "authOpenIDJwksURL":               issuer + "/jwks/",
        "authOpenIDLogoutURL":             "https://authentik.chifor.dev/application/o/audiobookshelf/end-session/",
        "authOpenIDClientID":              oidc["client_id"],
        "authOpenIDClientSecret":          oidc["client_secret"],
        "authOpenIDButtonText":            "Login with Authentik",
        "authOpenIDAutoLaunch":            False,
        "authOpenIDAutoRegister":          True,
        "authOpenIDMatchExistingBy":       "username",
        "authOpenIDSubfolderForRedirectURLs": "",
    }

    current = http("GET", "/api/auth-settings", token=token)
    diff = {k: v for k, v in desired.items() if current.get(k) != v}

    if not diff:
        print("  /api/auth-settings already matches desired state -- skip")
        return

    keys_to_show = sorted(k for k in diff if "Secret" not in k and "ClientID" not in k)
    print(f"  PATCH /api/auth-settings -- fields to update: {keys_to_show}")
    http("PATCH", "/api/auth-settings", body=diff, token=token, expect_json=False)


def main():
    print(f"Audiobookshelf bootstrap  ns={NAMESPACE!r}  url={PUBLIC_URL!r}")

    # 1. Pull OIDC credentials from the k8s Secret the authentik bootstrap wrote.
    oidc = {
        "client_id":     kubectl_secret("client-id"),
        "client_secret": kubectl_secret("client-secret"),
        "issuer":        kubectl_secret("issuer-url"),
    }
    print(f"  OIDC client_id={oidc['client_id'][:8]}...  issuer={oidc['issuer']}")

    # 2. Decide the admin password.
    desired_pw = ADMIN_PASS or "".join(
        secrets.choice(string.ascii_letters + string.digits) for _ in range(24)
    )
    generated = ADMIN_PASS is None

    # 3. Init or login.
    st = status()
    if not st.get("isInit"):
        print(f"  isInit=false -- creating initial admin")
        # Defence in depth: write the generated password to a temp file BEFORE
        # the API call. If a downstream print crashes (Windows console + Unicode
        # we've hit before), the operator still has a recoverable copy.
        if generated:
            import tempfile
            tmp = os.path.join(tempfile.gettempdir(), "audiobookshelf-admin-pass.txt")
            with open(tmp, "w") as f:
                f.write(desired_pw + "\n")
            print(f"  (saved password to {tmp} as a recovery backup)")
        init_admin(ADMIN_USER, desired_pw)
        token = login(ADMIN_USER, desired_pw)
    else:
        print(f"  isInit=true -- already has an admin user")
        if not ADMIN_PASS:
            sys.exit(
                "ERROR: ABS already initialized but AUDIOBOOKSHELF_ADMIN_PASSWORD\n"
                "is not set. Either:\n"
                "  - export it and re-run, OR\n"
                "  - wipe /config to start fresh: kubectl -n audiobookshelf delete\n"
                "    pvc audiobookshelf-config && helm upgrade ... && re-run"
            )
        token = login(ADMIN_USER, ADMIN_PASS)
        generated = False

    # 4. Wire OIDC.
    configure_oidc(token, oidc)

    # 5. Verify OIDC is now in /status's authMethods.
    st = status()
    methods = st.get("authMethods", [])
    if "openid" in methods:
        print(f"  /status authMethods = {methods}  -- Authentik OIDC live")
    else:
        sys.exit(f"WARNING: PATCH succeeded but authMethods is {methods}, expected to include 'openid'")

    print("\nDONE.")
    if generated:
        print(f"\nADMIN PASSWORD: {desired_pw}")
        print(f"USER: {ADMIN_USER}")
        print("\n(save it in Vaultwarden -- this is the only time you'll see it)")


if __name__ == "__main__":
    main()
