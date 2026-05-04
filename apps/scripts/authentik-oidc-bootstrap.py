#!/usr/bin/env python3
"""
Authentik OIDC bootstrap script for the homelab.

Creates an OAuth2/OpenID provider + application in Authentik for each
downstream app (Grafana, ArgoCD, Gitea, Vaultwarden), then writes a
Kubernetes Secret in each app's namespace with the resulting
client_id + client_secret + issuer URL.

Run from the repo root:
    cd ~/work/home/homelab
    . apps/charts/authentik-values/.secrets.env
    python apps/scripts/authentik-oidc-bootstrap.py

Idempotent: if an Application with the same slug already exists, the
script reuses its provider rather than creating a duplicate.

Requires:
- Python 3.9+
- requests, kubernetes (pip install requests kubernetes)
- AUTHENTIK_ADMIN_TOKEN env var (the bootstrap token from authentik install)
- KUBECONFIG pointing at the cluster (or in-cluster mode)

After this runs, you still need to `helm upgrade` each downstream app with
OIDC enabled — see the per-app READMEs in apps/charts/<app>-values/.
"""
import json
import os
import sys
from typing import Optional

try:
    import requests
except ImportError:
    sys.exit("ERROR: pip install requests")

AUTHENTIK_URL = os.getenv("AUTHENTIK_URL", "https://authentik.chifor.dev")
AUTHENTIK_TOKEN = os.getenv("AUTHENTIK_ADMIN_TOKEN")
if not AUTHENTIK_TOKEN:
    sys.exit("ERROR: AUTHENTIK_ADMIN_TOKEN env var not set; source apps/charts/authentik-values/.secrets.env first")

S = requests.Session()
S.headers.update({"Authorization": f"Bearer {AUTHENTIK_TOKEN}", "Content-Type": "application/json"})
S.verify = True


def api(path: str, method: str = "GET", json_body: Optional[dict] = None) -> dict:
    url = f"{AUTHENTIK_URL}/api/v3{path}"
    r = S.request(method, url, json=json_body, timeout=30)
    if r.status_code >= 400:
        sys.exit(f"ERROR: {method} {url} ==> {r.status_code}\n{r.text[:500]}")
    return r.json() if r.text else {}


def find_or_make(endpoint: str, search_field: str, search_value: str, create_payload: dict) -> dict:
    """GET endpoint?search_field=value ==> return first hit, else POST create_payload.

    Caveat: only works for fields that Authentik actually treats as filters
    (e.g. /providers/oauth2/ honours `?name=`). The /core/applications/
    endpoint silently ignores `?slug=` and returns the full unfiltered list,
    which would make this helper falsely match the first existing app —
    use get_or_make_application() instead for that endpoint.
    """
    existing = api(f"{endpoint}?{search_field}={search_value}").get("results", [])
    if existing:
        return existing[0]
    return api(endpoint, "POST", create_payload)


def get_or_make_application(slug: str, create_payload: dict) -> dict:
    """GET /core/applications/<slug>/ or POST to create.

    Authentik exposes applications as a slug-keyed resource, and the
    list endpoint's `?slug=` filter is silently ignored — so this is the
    only reliable exact-match lookup.
    """
    url = f"{AUTHENTIK_URL}/api/v3/core/applications/{slug}/"
    r = S.get(url, timeout=30)
    if r.status_code == 200:
        return r.json()
    if r.status_code == 404:
        return api("/core/applications/", "POST", create_payload)
    sys.exit(f"ERROR: GET {url} ==> {r.status_code}\n{r.text[:500]}")


def get_flow(slug: str) -> str:
    flows = api(f"/flows/instances/?slug={slug}").get("results", [])
    if not flows:
        sys.exit(f"ERROR: flow '{slug}' not found; check Authentik admin")
    return flows[0]["pk"]


def get_default_authorization_flow() -> str:
    return get_flow("default-provider-authorization-implicit-consent")


def get_default_invalidation_flow() -> str:
    """Authentik 2024.10+ requires invalidation_flow on OAuth2 providers."""
    return get_flow("default-provider-invalidation-flow")


def get_scope_mappings() -> list[str]:
    """Return PKs of the default openid + email + profile scope mappings."""
    scopes = api("/propertymappings/provider/scope/?ordering=name").get("results", [])
    wanted = {"authentik default OAuth Mapping: OpenID 'email'",
              "authentik default OAuth Mapping: OpenID 'openid'",
              "authentik default OAuth Mapping: OpenID 'profile'"}
    return [s["pk"] for s in scopes if s.get("name") in wanted]


def get_signing_key() -> str:
    """Use the default certificate Authentik generates on install."""
    certs = api("/crypto/certificatekeypairs/?has_key=true").get("results", [])
    for c in certs:
        if "authentik Self-signed Certificate" in c.get("name", ""):
            return c["pk"]
    if certs:
        return certs[0]["pk"]
    sys.exit("ERROR: no signing key in Authentik")


def upsert_oauth_app(slug: str, name: str, redirect_uris: list[str],
                     auth_flow: str, invalidation_flow: str,
                     scopes: list[str], signing_key: str) -> dict:
    """Create (or fetch) provider + application; return dict with client_id/client_secret/slug."""

    desired_redirect_uris = [{"matching_mode": "strict", "url": u} for u in redirect_uris]

    # 1. Provider
    provider = find_or_make(
        "/providers/oauth2/", "name", f"{name} OAuth",
        {
            "name": f"{name} OAuth",
            "authorization_flow": auth_flow,
            "invalidation_flow": invalidation_flow,
            "client_type": "confidential",
            "redirect_uris": desired_redirect_uris,
            "property_mappings": scopes,
            "signing_key": signing_key,
            "access_token_validity": "minutes=60",
            "refresh_token_validity": "days=30",
        },
    )

    # Reconcile redirect_uris on a pre-existing provider — find_or_make returns
    # the existing record unchanged, so a corrected URI in this script wouldn't
    # otherwise propagate to Authentik until the provider was deleted.
    if provider.get("redirect_uris") != desired_redirect_uris:
        print(f"  reconciling redirect_uris on existing provider {provider['pk']}")
        provider = api(f"/providers/oauth2/{provider['pk']}/", "PATCH",
                       {"redirect_uris": desired_redirect_uris})

    # 2. Application linked to provider
    app = get_or_make_application(
        slug,
        {
            "name": name,
            "slug": slug,
            "provider": provider["pk"],
            "policy_engine_mode": "any",
        },
    )

    issuer = f"{AUTHENTIK_URL}/application/o/{slug}/"
    return {
        "name": name,
        "slug": slug,
        "client_id": provider["client_id"],
        "client_secret": provider["client_secret"],
        "issuer": issuer,
    }


# === Apps to integrate ===
#
# `secret_labels` (optional): extra metadata.labels to set on the Secret.
#   ArgoCD's `$<secret>:<key>` substitution mechanism only reads from Secrets
#   carrying `app.kubernetes.io/part-of: argocd` — without it, ArgoCD passes
#   the literal placeholder string through as the OAuth client_id and Authentik
#   rejects the login with an "invalid client" error.
APPS = [
    {
        "slug": "grafana",
        "name": "Grafana",
        "redirect_uris": ["https://grafana.chifor.dev/login/generic_oauth"],
        "namespace": "monitoring",
    },
    {
        "slug": "argocd",
        "name": "ArgoCD",
        "redirect_uris": ["https://argocd.chifor.dev/auth/callback"],
        "namespace": "argocd",
        "secret_labels": {"app.kubernetes.io/part-of": "argocd"},
    },
    {
        "slug": "gitea",
        "name": "Gitea",
        # Gitea's OAuth callback URL embeds the auth source name verbatim:
        # /user/oauth2/<auth-source-name>/callback. The README's
        # `gitea admin auth add-oauth --name "Authentik"` produces the URL
        # below; Authentik's strict matching is case-sensitive, so the path
        # segment must be `Authentik`, not `authentik`.
        "redirect_uris": ["https://gitea.chifor.dev/user/oauth2/Authentik/callback"],
        "namespace": "gitea",
    },
    {
        "slug": "vaultwarden",
        "name": "Vaultwarden",
        "redirect_uris": ["https://vaultwarden.chifor.dev/identity/connect/oidc-signin"],
        "namespace": "vaultwarden",
    },
    {
        "slug": "immich",
        "name": "Immich",
        # Web flow + Immich mobile app (custom URI scheme registered with the
        # OS-level handler). Both must be present or mobile sign-in fails.
        "redirect_uris": [
            "https://immich.chifor.dev/auth/login",
            "https://immich.chifor.dev/user-settings",
            "app.immich:///oauth-callback",
        ],
        "namespace": "immich",
    },
    {
        "slug": "paperless",
        "name": "Paperless-ngx",
        # django-allauth pattern. The `authentik` segment matches the provider
        # key in PAPERLESS_SOCIALACCOUNT_PROVIDERS (see paperless README).
        # Trailing slash is required — Django redirects /callback to /callback/.
        "redirect_uris": ["https://paperless.chifor.dev/accounts/oidc/authentik/login/callback/"],
        "namespace": "paperless",
    },
    {
        "slug": "node-red",
        "name": "Node-RED",
        # passport-openidconnect default callback when configured via Node-RED's
        # adminAuth in settings.js (see node-red README).
        "redirect_uris": ["https://nodered.chifor.dev/auth/strategy/callback"],
        "namespace": "node-red",
    },
]


def write_k8s_secret(namespace: str, name: str, data: dict, labels: Optional[dict] = None) -> None:
    """Apply a Secret via kubectl (avoids requiring the kubernetes Python client)."""
    import base64
    encoded = {k: base64.b64encode(v.encode()).decode() for k, v in data.items()}
    metadata: dict = {"name": name, "namespace": namespace}
    if labels:
        metadata["labels"] = labels
    body = {
        "apiVersion": "v1",
        "kind": "Secret",
        "metadata": metadata,
        "type": "Opaque",
        "data": encoded,
    }
    import subprocess, tempfile
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
        json.dump(body, f)
        tmp = f.name
    r = subprocess.run(["kubectl", "apply", "-f", tmp], capture_output=True, text=True)
    os.unlink(tmp)
    if r.returncode != 0:
        sys.exit(f"ERROR: kubectl apply failed:\n{r.stderr}")
    print(f"  OK Secret {namespace}/{name}: {r.stdout.strip()}")


def main():
    print(f"Bootstrapping Authentik OIDC for {len(APPS)} app(s) at {AUTHENTIK_URL}")
    auth_flow = get_default_authorization_flow()
    invalidation_flow = get_default_invalidation_flow()
    scopes = get_scope_mappings()
    signing_key = get_signing_key()

    if not scopes:
        sys.exit("ERROR: no openid/email/profile scope mappings — check Authentik install")

    summary = []
    for app in APPS:
        print(f"\n==> {app['name']} ({app['slug']})")
        result = upsert_oauth_app(
            slug=app["slug"],
            name=app["name"],
            redirect_uris=app["redirect_uris"],
            auth_flow=auth_flow,
            invalidation_flow=invalidation_flow,
            scopes=scopes,
            signing_key=signing_key,
        )
        write_k8s_secret(
            namespace=app["namespace"],
            name="authentik-oidc",
            data={
                "client-id": result["client_id"],
                "client-secret": result["client_secret"],
                "issuer-url": result["issuer"],
            },
            labels=app.get("secret_labels"),
        )
        print(f"  client_id    = {result['client_id']}")
        print(f"  client_secret= {result['client_secret']}")
        print(f"  issuer       = {result['issuer']}")
        summary.append(result)

    # Print summary block
    print("\n" + "=" * 70)
    print("DONE. Secrets written to each app's namespace as `authentik-oidc`.")
    print("Next: helm upgrade each app with OIDC config — see per-app READMEs.")
    print("=" * 70)


if __name__ == "__main__":
    main()
