#!/usr/bin/env python3
"""
Navidrome admin password bootstrap.

Why this script exists: Navidrome's `admin` user is auto-created from the
X-authentik-username header on first reverse-proxy-auth web-UI request,
with a RANDOM password the operator never sees. The Subsonic API (used
by mobile clients like Amperfy) needs that password. The web "Personal"
form refuses to change it without the old one. This script is the
clean recovery path.

Behavior (idempotent):
  - admin user exists, NAVIDROME_PASSWORD provided, Subsonic ping works
        -> no-op, exit 0
  - admin user missing
        -> trigger reverse-proxy auto-create via /app/ + X-authentik-username
           header from a 10.42 source IP (curl pod inside the namespace),
           then PATCH new password via /api/user/{id}
  - admin user exists but auth doesn't work (password drifted, or fresh
    reset asked via FORCE_RESET=1)
        -> DELETE the user row, recreate via reverse-proxy header, PATCH new pw

Usage (from operator machine, with kubectl context on the cluster):

    cd ~/work/home/homelab
    # first run (generates + prints a fresh password):
    python apps/scripts/navidrome-defaults.py

    # explicit password (e.g. set up before, want it to stay the same after
    # a Navidrome reinstall):
    NAVIDROME_PASSWORD='your-pass' python apps/scripts/navidrome-defaults.py

    # forcibly reset even if the current password works:
    NAVIDROME_FORCE_RESET=1 python apps/scripts/navidrome-defaults.py

Environment overrides:
    NAVIDROME_NAMESPACE    (default: navidrome)
    NAVIDROME_DEPLOY       (default: navidrome)
    NAVIDROME_USERNAME     (default: admin)
    NAVIDROME_PUBLIC_URL   (default: https://music.chifor.dev)
    NAVIDROME_PASSWORD     (default: random 20 chars, alphanumeric)
    NAVIDROME_FORCE_RESET  (default: 0; "1"/"true"/"yes" forces reset)

Stdlib-only (no pip deps); shells out to kubectl.
"""
import json
import os
import secrets
import string
import subprocess
import sys
import time
import urllib.parse
import urllib.request


NAMESPACE  = os.getenv("NAVIDROME_NAMESPACE", "navidrome")
DEPLOY     = os.getenv("NAVIDROME_DEPLOY",    "navidrome")
USERNAME   = os.getenv("NAVIDROME_USERNAME",  "admin")
PUBLIC_URL = os.getenv("NAVIDROME_PUBLIC_URL", "https://music.chifor.dev").rstrip("/")
PASSWORD   = os.getenv("NAVIDROME_PASSWORD")
FORCE      = os.getenv("NAVIDROME_FORCE_RESET", "").lower() in ("1", "true", "yes")

SVC = f"{DEPLOY}.{NAMESPACE}.svc.cluster.local:4533"
DB  = "/data/navidrome.db"


def kubectl(*args, **kwargs) -> subprocess.CompletedProcess:
    return subprocess.run(["kubectl", "-n", NAMESPACE, *args],
                          capture_output=True, text=True, **kwargs)


def sqlite(query: str) -> str:
    r = kubectl("exec", f"deploy/{DEPLOY}", "--", "sqlite3", DB, query)
    if r.returncode != 0:
        sys.exit(f"ERROR: sqlite3 -> exit {r.returncode}\n{r.stderr}")
    return r.stdout.strip()


def find_admin() -> dict | None:
    """Return {id, pw_len} for USERNAME, or None if missing."""
    out = sqlite(f"SELECT id, length(password) FROM user WHERE user_name='{USERNAME}';")
    if not out:
        return None
    pk, pwlen = out.split("|", 1)
    return {"id": pk, "pw_len": int(pwlen)}


def curl_pod(name: str, args: list[str]) -> subprocess.CompletedProcess:
    """Run curl as a one-shot pod in the namespace -- gets a 10.42 IP that's
    in ND_REVERSEPROXYWHITELIST so the X-authentik-username header is honoured.
    """
    return subprocess.run(
        ["kubectl", "run", "--rm", "-i", "--restart=Never",
         "--image=curlimages/curl:8.10.1",
         "-n", NAMESPACE, name, "--", "curl", *args],
        capture_output=True, text=True,
    )


def trigger_recreate() -> bool:
    """Hit /app/ with the proxy header so Navidrome auto-creates the user."""
    print(f"  triggering reverse-proxy auto-create for {USERNAME!r}...")
    name = f"navidrome-recreate-{secrets.token_hex(3)}"
    r = curl_pod(name, [
        "-sS",
        "-H", f"X-authentik-username: {USERNAME}",
        "-o", "/dev/null", "-w", "%{http_code}",
        f"http://{SVC}/app/",
    ])
    if r.returncode != 0:
        sys.stderr.write(f"  curl pod failed: {r.stderr}\n")
        return False
    # User-table row sometimes lags a bit; poll up to 10 s.
    for _ in range(20):
        time.sleep(0.5)
        if find_admin():
            return True
    return False


def patch_password(admin_id: str, password: str) -> bool:
    """PUT /api/user/{id} via reverse-proxy auth (acts as admin)."""
    body = json.dumps({
        "id":       admin_id,
        "userName": USERNAME,
        "name":     USERNAME,
        "isAdmin":  True,
        "password": password,
    })
    name = f"navidrome-pwset-{secrets.token_hex(3)}"
    r = curl_pod(name, [
        "-sS", "-X", "PUT",
        "-H", f"X-authentik-username: {USERNAME}",
        "-H", "Content-Type: application/json",
        "-d", body,
        f"http://{SVC}/api/user/{admin_id}",
    ])
    if r.returncode != 0:
        sys.stderr.write(f"  curl pod failed: {r.stderr}\n")
        return False
    if '"error"' in r.stdout:
        sys.stderr.write(f"  PATCH error: {r.stdout}\n")
        return False
    return True


def verify_subsonic(password: str) -> bool:
    """Hit /rest/ping with the credentials; True if status:ok.

    Custom User-Agent: Cloudflare's Bot Fight Mode rejects the default
    `Python-urllib/X.Y` UA with HTTP 403 + error code 1010, so we have
    to identify ourselves as something less generic.
    """
    url = f"{PUBLIC_URL}/rest/ping?" + urllib.parse.urlencode({
        "u": USERNAME, "p": password, "v": "1.16.1",
        "c": "navidrome-defaults", "f": "json",
    })
    req = urllib.request.Request(url, headers={
        "User-Agent": "navidrome-defaults/1.0",
    })
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            data = json.loads(r.read())
        return data.get("subsonic-response", {}).get("status") == "ok"
    except Exception as e:
        sys.stderr.write(f"  /rest/ping check failed: {e}\n")
        return False


def main():
    print(f"Navidrome bootstrap  ns={NAMESPACE!r}  user={USERNAME!r}  url={PUBLIC_URL!r}")

    desired_pw = PASSWORD or "".join(
        secrets.choice(string.ascii_letters + string.digits) for _ in range(20)
    )
    generated = PASSWORD is None

    admin = find_admin()

    # === Path 1: user already exists, password env supplied + works -> skip ===
    if admin and PASSWORD and not FORCE and verify_subsonic(PASSWORD):
        print(f"  {USERNAME!r} exists, NAVIDROME_PASSWORD already accepted -- skip")
        return

    # === Path 2: forced reset, or user exists but password doesn't work ===
    if admin and (FORCE or (PASSWORD and not verify_subsonic(PASSWORD))):
        why = "FORCE_RESET=1" if FORCE else "supplied password rejected"
        print(f"  {USERNAME!r} exists ({why}) -- DELETE + recreate")
        sqlite(f"DELETE FROM user WHERE id='{admin['id']}';")
        admin = None

    # === Path 3: missing -> auto-create via reverse-proxy auth ===
    if admin is None:
        if not trigger_recreate():
            sys.exit(
                f"ERROR: failed to recreate {USERNAME!r}.\n"
                f"  - Check ND_REVERSEPROXYWHITELIST includes 10.42.0.0/16\n"
                f"  - Check ND_REVERSEPROXYUSERHEADER='X-authentik-username'\n"
                f"  - Check that {DEPLOY!r} is Running"
            )
        admin = find_admin()
        if not admin:
            sys.exit("ERROR: admin row didn't materialise after recreate poll")

    # === PATCH the password (admin row now exists with a Navidrome-encrypted
    # blob it can decrypt; safe to overwrite) ===
    print(f"  setting password on {USERNAME!r} (id={admin['id']})...")
    if not patch_password(admin["id"], desired_pw):
        sys.exit("ERROR: PATCH /api/user failed")

    # Verify end-to-end
    time.sleep(2)
    if not verify_subsonic(desired_pw):
        sys.exit(
            "ERROR: PATCH succeeded but /rest/ping rejected the new password.\n"
            "  Check Navidrome logs: kubectl -n navidrome logs deploy/navidrome --tail=20"
        )
    print(f"  /rest/ping -> ok")

    print()
    if generated:
        print(f"NEW PASSWORD: {desired_pw}")
        print(f"             save it in Vaultwarden -- the script does NOT persist it.")
    else:
        print(f"Password set from NAVIDROME_PASSWORD env.")


if __name__ == "__main__":
    main()
