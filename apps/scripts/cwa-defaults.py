#!/usr/bin/env python3
"""
Calibre-Web Automated (CWA) admin password bootstrap.

Why this script exists:
  1. CWA <= V3.1.4 has a bug where the admin user-list "Edit User" form
     reports success on password change but doesn't actually emit the
     UPDATE. The /me self-edit form works; the admin-list one doesn't.
  2. Some CWA upgrades (we hit V3.1.4 -> v4.0.6 first-hand) corrupt the
     password column during DB migration -- the hash is physically in
     app.db but `werkzeug.security.check_password_hash` rejects it.
  3. CWA's first-launch admin/admin123 default needs to be rotated
     immediately and the obvious UI path is the broken one.

The script writes a Werkzeug-compatible scrypt hash directly into
/config/app.db using the CWA pod's own Python (so the hash format always
matches what the running CWA version expects), then verifies via the
public web flow (CSRF-aware POST /login + authenticated /me probe).

Behavior (idempotent):
  - CWA_ADMIN_PASSWORD set + web-login already accepts it -> no-op skip
  - CWA_ADMIN_PASSWORD set + web-login rejects it (drift / migration
    corruption / first-time)                              -> reset hash
  - CWA_ADMIN_PASSWORD missing                             -> generate
    random 20-char password, reset, print at end. Defence-in-depth:
    saved to $TEMP/cwa-admin-pass.txt before the DB write so a print
    crash doesn't lose it.

Usage:
    cd ~/work/home/homelab
    # fresh / reset (random pw printed at end):
    python apps/scripts/cwa-defaults.py

    # stable known pw across reinstalls / upgrades:
    CWA_ADMIN_PASSWORD='your-pass' python apps/scripts/cwa-defaults.py

Environment overrides:
    CWA_NAMESPACE       (default: cwa)
    CWA_DEPLOY          (default: cwa)
    CWA_PUBLIC_URL      (default: https://books.chifor.dev)
    CWA_ADMIN_USER      (default: admin)
    CWA_ADMIN_PASSWORD  (default: random 20 chars)

Stdlib-only Python; shells out to kubectl for the in-pod hashing + UPDATE.
"""
import http.cookiejar
import os
import re
import secrets
import string
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request


NAMESPACE  = os.getenv("CWA_NAMESPACE", "cwa")
DEPLOY     = os.getenv("CWA_DEPLOY",    "cwa")
PUBLIC_URL = os.getenv("CWA_PUBLIC_URL", "https://books.chifor.dev").rstrip("/")
ADMIN_USER = os.getenv("CWA_ADMIN_USER", "admin")
ADMIN_PASS = os.getenv("CWA_ADMIN_PASSWORD")

# Cloudflare's Bot Fight Mode rejects Python-urllib's default UA.
UA = "cwa-defaults/1.0"


def in_pod_python(script: str, extra_env: dict | None = None) -> str:
    """Run a Python snippet inside the CWA pod. extra_env is passed via
    `kubectl exec ... env K=V K2=V2 -- python3 -c ...` so we never embed
    secrets in the inline script string and no shell escaping bites us."""
    cmd = ["kubectl", "-n", NAMESPACE, "exec", f"deploy/{DEPLOY}", "--"]
    if extra_env:
        cmd.append("env")
        for k, v in extra_env.items():
            cmd.append(f"{k}={v}")
    cmd += ["python3", "-c", script]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"ERROR: in-pod python failed:\n{r.stderr}")
    return r.stdout.strip()


def web_login(password: str) -> bool:
    """CSRF-aware POST /login + authenticated /me probe.
    Returns True iff login succeeds (i.e. /me doesn't redirect to /login).
    Custom User-Agent so Cloudflare Bot Fight Mode doesn't 403."""
    jar = http.cookiejar.CookieJar()
    op = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
    op.addheaders = [("User-Agent", UA)]
    try:
        html = op.open(f"{PUBLIC_URL}/login", timeout=15).read().decode("utf-8", errors="replace")
    except Exception as e:
        sys.stderr.write(f"  GET /login failed: {e}\n")
        return False

    m = re.search(r'name="csrf_token"\s+value="([^"]+)"', html)
    if not m:
        sys.stderr.write("  no csrf_token in /login HTML -- form layout changed?\n")
        return False
    csrf = m.group(1)

    body = urllib.parse.urlencode({
        "username":   ADMIN_USER,
        "password":   password,
        "csrf_token": csrf,
        "submit":     "Submit",
    }).encode()
    try:
        op.open(urllib.request.Request(
            f"{PUBLIC_URL}/login", data=body, method="POST",
            headers={"Content-Type": "application/x-www-form-urlencoded"}
        ), timeout=15)
        me = op.open(f"{PUBLIC_URL}/me", timeout=15)
        return "/login" not in me.geturl()
    except urllib.error.HTTPError as e:
        sys.stderr.write(f"  /login or /me HTTPError {e.code}\n")
        return False
    except Exception as e:
        sys.stderr.write(f"  login flow error: {e}\n")
        return False


def reset_password(password: str) -> None:
    """Hash via the pod's werkzeug + parameterized UPDATE in /config/app.db."""
    print(f"  hashing inside pod + UPDATE user.password (parameterized)")
    out = in_pod_python(
        """
import os, sqlite3
from werkzeug.security import generate_password_hash, check_password_hash
pw   = os.environ['NP']
user = os.environ['NU']
h = generate_password_hash(pw, method='scrypt')
conn = sqlite3.connect('/config/app.db')
n = conn.execute("UPDATE user SET password=? WHERE name=?", (h, user)).rowcount
conn.commit()
if n == 0:
    raise SystemExit(f"ERROR: no user named {user!r} in /config/app.db -- has CWA finished its first-launch init?")
got = conn.execute("SELECT password FROM user WHERE name=?", (user,)).fetchone()
ok = check_password_hash(got[0], pw)
print(f"hash_format={h[:16]}")
print(f"hash_length={len(h)}")
print(f"round_trip_verify={ok}")
conn.close()
""",
        extra_env={"NP": password, "NU": ADMIN_USER},
    )
    for ln in out.splitlines():
        print(f"  {ln}")
    if "round_trip_verify=True" not in out:
        sys.exit("ERROR: in-DB hash failed local check_password_hash round-trip; aborting")


def main() -> None:
    print(f"CWA bootstrap  ns={NAMESPACE!r}  deploy={DEPLOY!r}  url={PUBLIC_URL!r}")

    # 1. Decide the desired password.
    desired = ADMIN_PASS or "".join(
        secrets.choice(string.ascii_letters + string.digits) for _ in range(20)
    )
    generated = ADMIN_PASS is None

    # Defence in depth: save to $TEMP before the DB write so a downstream
    # print crash doesn't lose the value.
    if generated:
        import tempfile
        backup = os.path.join(tempfile.gettempdir(), "cwa-admin-pass.txt")
        with open(backup, "w") as f:
            f.write(desired + "\n")
        print(f"  (saved generated password to {backup} as recovery backup)")

    # 2. Path-of-no-op: if the supplied password already works, exit quiet.
    if ADMIN_PASS and web_login(ADMIN_PASS):
        print(f"  CWA_ADMIN_PASSWORD already accepts /login -- skip")
        return

    # 3. Reset.
    reset_password(desired)

    # 4. Web-flow verify (gives the CWA process a moment to flush user cache).
    time.sleep(2)
    if web_login(desired):
        print("  /me probe -- AUTH OK")
    else:
        sys.exit(
            "WARNING: hash written + round-trip verified in DB, but web login\n"
            "still rejects. Restart the pod to flush any in-memory user cache:\n"
            f"  kubectl -n {NAMESPACE} rollout restart deploy/{DEPLOY}"
        )

    print("\nDONE.")
    if generated:
        print(f"\nADMIN PASSWORD: {desired}")
        print(f"USER: {ADMIN_USER}")
        print("\n(save it in Vaultwarden; this is the only time you'll see it printed)")


if __name__ == "__main__":
    main()
