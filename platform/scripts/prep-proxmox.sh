#!/usr/bin/env bash
# scripts/prep-proxmox.sh
#
# Idempotent Proxmox-host prep for the homelab OpenTofu project.
# Run as root on the Proxmox host. Safe to re-run.
#
# What it does:
#   1. Creates the OpenTofu API user + token (Administrator at /).
#   2. Downloads the Alpine LXC template if missing.
#   3. Creates the Debian-12 cloud-init template VM (VMID 9000) if missing.
#   4. Read-only sanity check of /etc/network/interfaces and bond0 LACP.
#   5. Installs host diagnostic tools (nvme-cli) if missing.
#   6. Prints a summary of state and reminders for the things only you can do.
#
# Override defaults via env vars (see "Config" block).

set -euo pipefail

# ============================================================================
# Config (override via env vars at invocation, e.g. ALPINE_VERSION=3.22 ./...)
# ============================================================================
TOFU_USER="${TOFU_USER:-tofu-prov@pve}"
TOFU_TOKEN_NAME="${TOFU_TOKEN_NAME:-tofu-token}"
TOFU_USER_PASSWORD="${TOFU_USER_PASSWORD:-}"   # if empty, prompt interactively

TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
ALPINE_VERSION="${ALPINE_VERSION:-3.23}"

DEBIAN_VMID="${DEBIAN_VMID:-9000}"
DEBIAN_TEMPLATE_NAME="${DEBIAN_TEMPLATE_NAME:-debian-12-cloudinit-template}"
DEBIAN_VM_STORAGE="${DEBIAN_VM_STORAGE:-local-zfs}"
DEBIAN_QCOW_URL="${DEBIAN_QCOW_URL:-https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2}"

# ============================================================================
# Helpers
# ============================================================================
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()   { printf "${GREEN}\xe2\x9c\x93${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}\xe2\x9a\xa0${NC} %s\n" "$*"; }
fail() { printf "${RED}\xe2\x9c\x97${NC} %s\n" "$*" >&2; }
step() { printf "\n${CYAN}==>${NC} %s\n" "$*"; }
die()  { fail "$*"; exit 1; }

# ============================================================================
# Pre-flight
# ============================================================================
[ "$(id -u)" = "0" ]            || die "Run as root."
command -v pveum >/dev/null     || die "pveum not found — is this a Proxmox host?"
command -v pveam >/dev/null     || die "pveam not found."
command -v qm    >/dev/null     || die "qm not found."
command -v wget  >/dev/null     || die "wget not found (needed for the Debian qcow2)."

# Track state for the final summary.
NAS_TEMPLATE_VOLID=""
TOKEN_FRESHLY_CREATED=0

# ============================================================================
# Step 1: API user + token
# ============================================================================
step "Step 1/5: API user + token"

user_exists() {
  pveum user list --noborder --noheader 2>/dev/null | awk '{print $1}' | grep -qx "$1"
}

token_exists() {
  pveum user token list "$1" --noborder --noheader 2>/dev/null | awk '{print $1}' | grep -qx "$2"
}

if user_exists "$TOFU_USER"; then
  ok "User '$TOFU_USER' already exists"
else
  warn "Creating user '$TOFU_USER'"
  if [ -z "$TOFU_USER_PASSWORD" ]; then
    read -r -s -p "  Set a password for $TOFU_USER (the token will be used at runtime, not this): " TOFU_USER_PASSWORD
    echo
  fi
  pveum user add "$TOFU_USER" --password "$TOFU_USER_PASSWORD"
  unset TOFU_USER_PASSWORD
  ok "User created"
fi

# Always ensure Administrator role at / (idempotent — pveum aclmod is set-style).
pveum aclmod / -user "$TOFU_USER" -role Administrator >/dev/null
ok "Administrator role granted at / (idempotent)"

if token_exists "$TOFU_USER" "$TOFU_TOKEN_NAME"; then
  ok "Token '$TOFU_TOKEN_NAME' already exists for $TOFU_USER"
  echo "    Token ID for tfvars: ${TOFU_USER}!${TOFU_TOKEN_NAME}"
  echo "    (Secret is not printed — Proxmox shows it only once at creation.)"
  echo "    If you've lost the secret, delete + recreate:"
  echo "      pveum user token remove $TOFU_USER $TOFU_TOKEN_NAME"
  echo "      ./prep-proxmox.sh"

  # Ensure privsep=0 on the existing token (idempotent). Without this, the
  # token has its own empty ACL set and the Telmate provider fails with
  # 'cannot retrieve user list, check privilege separation of api token'.
  CURRENT_PRIVSEP=$(pveum user token list "$TOFU_USER" --noborder --noheader 2>/dev/null \
    | awk -v t="$TOFU_TOKEN_NAME" '$1==t {print $4; exit}')
  if [ "$CURRENT_PRIVSEP" = "1" ]; then
    warn "Token has privsep=1 — flipping to 0 (preserves the secret)"
    pveum user token modify "$TOFU_USER" "$TOFU_TOKEN_NAME" --privsep 0 >/dev/null
    ok "Token privsep is now 0"
  else
    ok "Token privsep already 0"
  fi
else
  warn "Creating token '$TOFU_TOKEN_NAME' (privsep=0)"
  # pveum prints a table with 'value' column — capture verbatim.
  TOKEN_OUT="$(pveum user token add "$TOFU_USER" "$TOFU_TOKEN_NAME" --privsep 0 2>&1)"
  TOKEN_FRESHLY_CREATED=1
  echo
  echo "============================================================"
  echo "  Token created. SAVE THE 'value' FIELD — it is shown only once."
  echo "============================================================"
  printf "%s\n" "$TOKEN_OUT"
  echo "============================================================"
  echo
  echo "  On your operator machine (PowerShell):"
  echo "    \$env:TF_VAR_pm_api_token_secret = '<value-from-table-above>'"
  echo "  In terraform.tfvars:"
  echo "    pm_api_token_id = '${TOFU_USER}!${TOFU_TOKEN_NAME}'"
fi

# ============================================================================
# Step 2: Alpine LXC template
# ============================================================================
step "Step 2/5: Alpine ${ALPINE_VERSION} LXC template"

if ! pveam update >/dev/null 2>&1; then
  warn "pveam update failed (no internet?). Proceeding with the local catalog cache."
fi

# Latest matching template available in Proxmox's catalog.
LATEST_ALPINE=$(pveam available --section system 2>/dev/null \
                | awk '{print $2}' \
                | grep -E "^alpine-${ALPINE_VERSION}-default_.*_amd64\.tar\.xz$" \
                | sort | tail -1 || true)

# Latest matching template already on the storage.
EXISTING=$(pveam list "$TEMPLATE_STORAGE" 2>/dev/null \
           | awk '{print $1}' \
           | awk -F/ '{print $NF}' \
           | grep -E "^alpine-${ALPINE_VERSION}-default_.*_amd64\.tar\.xz$" \
           | sort | tail -1 || true)

if [ -n "$EXISTING" ]; then
  ok "Alpine template already on '$TEMPLATE_STORAGE': $EXISTING"
  NAS_TEMPLATE_VOLID="${TEMPLATE_STORAGE}:vztmpl/${EXISTING}"
elif [ -n "$LATEST_ALPINE" ]; then
  warn "Downloading $LATEST_ALPINE → $TEMPLATE_STORAGE"
  pveam download "$TEMPLATE_STORAGE" "$LATEST_ALPINE"
  ok "Downloaded: $LATEST_ALPINE"
  NAS_TEMPLATE_VOLID="${TEMPLATE_STORAGE}:vztmpl/${LATEST_ALPINE}"
else
  fail "No alpine-${ALPINE_VERSION}-* template available locally OR in the Proxmox catalog."
  echo "    Try: ALPINE_VERSION=3.22 ./prep-proxmox.sh"
fi

# ============================================================================
# Step 3: Debian 12 cloud-init template VM
# ============================================================================
step "Step 3/5: Debian 12 cloud-init template VM (VMID $DEBIAN_VMID)"

if qm status "$DEBIAN_VMID" >/dev/null 2>&1; then
  CURRENT_NAME=$(qm config "$DEBIAN_VMID" 2>/dev/null | awk '/^name:/{print $2; exit}')
  if qm config "$DEBIAN_VMID" 2>/dev/null | grep -q '^template: 1$'; then
    ok "Template VM $DEBIAN_VMID exists (name: ${CURRENT_NAME:-?}, is a template)"
  else
    warn "VMID $DEBIAN_VMID exists but is NOT a template (name: ${CURRENT_NAME:-?})."
    echo "    To re-create from scratch: qm destroy $DEBIAN_VMID && ./prep-proxmox.sh"
  fi
else
  # Verify storage is reachable before downloading the qcow2.
  if ! pvesm status -storage "$DEBIAN_VM_STORAGE" >/dev/null 2>&1; then
    die "Storage '$DEBIAN_VM_STORAGE' not found (override DEBIAN_VM_STORAGE)."
  fi
  warn "Creating template VM $DEBIAN_VMID ($DEBIAN_TEMPLATE_NAME)"
  TMP_QCOW=$(mktemp /tmp/debian-12-genericcloud.XXXXXX.qcow2)
  trap 'rm -f "$TMP_QCOW"' EXIT
  echo "    Downloading $DEBIAN_QCOW_URL"
  wget -q --show-progress -O "$TMP_QCOW" "$DEBIAN_QCOW_URL"
  qm create "$DEBIAN_VMID" --name "$DEBIAN_TEMPLATE_NAME" --memory 2048 --net0 virtio,bridge=vmbr0
  qm importdisk "$DEBIAN_VMID" "$TMP_QCOW" "$DEBIAN_VM_STORAGE"
  # importdisk produces 'unused0:<storage>:vm-<vmid>-disk-0'; attach as scsi0.
  qm set "$DEBIAN_VMID" --scsihw virtio-scsi-single --scsi0 "${DEBIAN_VM_STORAGE}:vm-${DEBIAN_VMID}-disk-0"
  qm set "$DEBIAN_VMID" --ide2 "${DEBIAN_VM_STORAGE}:cloudinit"
  qm set "$DEBIAN_VMID" --boot c --bootdisk scsi0
  qm set "$DEBIAN_VMID" --serial0 socket --vga serial0
  qm set "$DEBIAN_VMID" --agent enabled=1
  qm template "$DEBIAN_VMID"
  rm -f "$TMP_QCOW"
  trap - EXIT
  ok "Template VM $DEBIAN_VMID created and converted to template"
fi

# ============================================================================
# Step 4: Network / bond sanity (read-only)
# ============================================================================
step "Step 4/5: Network sanity (read-only)"

if grep -qE '^auto bond0' /etc/network/interfaces 2>/dev/null && \
   grep -qE '^auto vmbr0' /etc/network/interfaces 2>/dev/null; then
  ok "/etc/network/interfaces has bond0 + vmbr0 stanzas"
else
  warn "/etc/network/interfaces does NOT contain both 'auto bond0' and 'auto vmbr0'."
  echo "    See README §3 for the reference config. NOT auto-modified (too risky)."
fi

LACP_OK=0
if [ -r /proc/net/bonding/bond0 ]; then
  PORTS=$(awk '/Number of ports:/{print $4; exit}' /proc/net/bonding/bond0)
  PARTNER=$(awk '/Partner Mac Address/{print $4; exit}' /proc/net/bonding/bond0)
  MODE=$(awk -F': ' '/Bonding Mode/{print $2; exit}' /proc/net/bonding/bond0)
  if [ "$PORTS" = "2" ] && [ -n "$PARTNER" ] && [ "$PARTNER" != "00:00:00:00:00:00" ]; then
    ok "bond0 LACP synchronized: 2 ports, partner $PARTNER ($MODE)"
    LACP_OK=1
  elif echo "$MODE" | grep -qi 'active-backup'; then
    ok "bond0 in active-backup mode (1 active link, $PORTS port(s) in aggregator) — switch-side LAG not needed"
    LACP_OK=1
  else
    warn "bond0 LACP NOT synchronized (mode='$MODE', ports=$PORTS, partner=$PARTNER)"
    echo "    Configure LAG on the matching UniFi switch ports (Ctrl-click → Aggregate)."
  fi
else
  warn "/proc/net/bonding/bond0 not present — no bond configured."
fi

# ============================================================================
# Step 5: Host diagnostic tools
# ============================================================================
# nvme-cli is not part of the default Proxmox install but is the only way to
# read SMART (wear, temperature, media errors) from NVMe drives and to verify
# pool-disk health beyond what `zpool status` reports. Lightweight (~1 MB,
# zero runtime overhead — purely a CLI). Idempotent: dpkg-query short-circuits
# if already installed, so re-running prep doesn't re-fetch.
step "Step 5/5: Host diagnostic tools (nvme-cli)"

if dpkg-query -W -f='${Status}' nvme-cli 2>/dev/null | grep -q "ok installed"; then
  ok "nvme-cli already installed ($(nvme version 2>/dev/null | awk 'NR==1{print $3}'))"
else
  warn "nvme-cli missing; installing"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nvme-cli >/dev/null
  ok "nvme-cli installed ($(nvme version 2>/dev/null | awk 'NR==1{print $3}'))"
fi

# ============================================================================
# Summary
# ============================================================================
step "Summary"
cat <<EOF
  Proxmox node     : $(hostname)
  Token ID         : ${TOFU_USER}!${TOFU_TOKEN_NAME}
  NAS template     : ${NAS_TEMPLATE_VOLID:-<not available>}
  CP template VM   : $DEBIAN_VMID ($DEBIAN_TEMPLATE_NAME)
  bond0 status     : $([ "$LACP_OK" = 1 ] && echo OK || echo "NEEDS ATTENTION (see warnings above)")

Next steps:
  1. Run scripts/prep-worker.sh on each Radxa Q6A worker (as root).
  2. (Optional) From the operator machine: scripts/check-prereqs.ps1
  3. On the operator machine, in PowerShell:
       \$env:TF_VAR_pm_api_token_secret = "<token-secret-from-Step-1>"
       cd C:\\Users\\chifo\\work\\home\\homelab
       Copy-Item terraform.tfvars.example terraform.tfvars
       notepad terraform.tfvars     # paste pm_api_token_id, nas_template, cp_template_name
       terraform init
       # Then the two-phase first apply per README §"First apply"

EOF

if [ "$TOKEN_FRESHLY_CREATED" = "1" ]; then
  warn "REMINDER: scroll up and copy the token 'value' field — Proxmox will not show it again."
fi
