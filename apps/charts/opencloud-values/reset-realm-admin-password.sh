#!/bin/bash
# Reset the OpenCloud realm admin user's password to OC_ADMIN_PASSWORD.
#
# The chart's `opencloud-keycloak-realm` ConfigMap imports a demo realm with
# 6 hardcoded users (admin + alan/dennis/lynn/margaret/mary), each with an
# Argon2-hashed demo password baked into the realm export. Our
# --set "opencloud.adminPassword=..." doesn't override these — it sets a
# different (chart-internal) value. So fresh installs can't log in with
# the password we generated.
#
# This script logs into Keycloak's master realm as the chart-managed admin,
# then resets the openCloud realm admin user's password via the Admin API.
#
# Run after every `helm install` of opencloud (idempotent — safe to re-run).
#
# Requires: curl, python3, kubectl, and apps/charts/opencloud-values/.secrets.env

set -eu

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
. "$REPO_ROOT/apps/charts/opencloud-values/.secrets.env"

KEYCLOAK_URL="${KEYCLOAK_URL:-https://kc-cloud.chifor.dev}"
REALM="${REALM:-openCloud}"
USERNAME="${USERNAME:-admin}"

# Pull Keycloak's actual master-admin credentials from its k8s secret
# (the chart-rendered `keycloak.internal.adminPassword` value).
KC_ADMIN=$(kubectl -n opencloud get secret opencloud-keycloak -o jsonpath='{.data.adminUser}' | base64 -d)
KC_PASS=$(kubectl -n opencloud get secret opencloud-keycloak -o jsonpath='{.data.adminPassword}' | base64 -d)
[ -n "$KC_ADMIN" ] || { echo "ERROR: opencloud-keycloak Secret missing 'adminUser' key" >&2; exit 1; }

echo "Resetting realm '$REALM' user '$USERNAME' password to OC_ADMIN_PASSWORD..."

# 1. Get an admin access token from the master realm
TOKEN=$(curl -sS -X POST "$KEYCLOAK_URL/realms/master/protocol/openid-connect/token" \
  -d "username=$KC_ADMIN" \
  -d "password=$KC_PASS" \
  -d "grant_type=password" \
  -d "client_id=admin-cli" \
  | python -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))")
[ -n "$TOKEN" ] || { echo "ERROR: failed to obtain Keycloak admin token" >&2; exit 1; }

# 2. Look up the user ID in the openCloud realm
USER_ID=$(curl -sS -H "Authorization: Bearer $TOKEN" \
  "$KEYCLOAK_URL/admin/realms/$REALM/users?username=$USERNAME&exact=true" \
  | python -c "import sys,json; r=json.load(sys.stdin); print(r[0]['id'] if r else '')")
[ -n "$USER_ID" ] || { echo "ERROR: user '$USERNAME' not found in realm '$REALM'" >&2; exit 1; }

# 3. PUT the new password (temporary=false → no forced change on next login)
HTTP=$(curl -sS -X PUT -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  "$KEYCLOAK_URL/admin/realms/$REALM/users/$USER_ID/reset-password" \
  -d "{\"type\":\"password\",\"value\":\"$OC_ADMIN_PASSWORD\",\"temporary\":false}" \
  -o /dev/null -w "%{http_code}")

if [ "$HTTP" = "204" ]; then
  echo "OK: realm '$REALM' user '$USERNAME' password reset to OC_ADMIN_PASSWORD."
  echo "    Login at https://cloud.chifor.dev with username '$USERNAME' and that password."
else
  echo "ERROR: password reset returned HTTP $HTTP" >&2
  exit 1
fi
