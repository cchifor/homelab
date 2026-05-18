#!/usr/bin/env bash
# scripts/prep-worker-incus.sh
#
# One-time Incus 7.0 installer for Q6A workers that ALSO run k3s on bare
# metal. Idempotent: safe to re-run; each step is checked-before-acted.
#
# Args:
#   $1  Path to preseed YAML to apply on first init (default
#       /tmp/preseed-worker.yaml; install-incus-workers.sh scp's it there).
#
# Prereq: /dev/kvm must be exposed. Toggle in Qualcomm UEFI:
#   F2 during boot splash → Hypervisor Settings → Hypervisor Override →
#   enable → save & exit. Setting persists in UEFI NVRAM.
#
# Without /dev/kvm the install completes but `incus launch <name> --vm` fails
# at QEMU startup. LXC containers still work — but the install is half-useful.

set -euo pipefail

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()   { printf "${GREEN}\xe2\x9c\x93${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}\xe2\x9a\xa0${NC} %s\n" "$*"; }
fail() { printf "${RED}\xe2\x9c\x97${NC} %s\n" "$*" >&2; }
step() { printf "\n${CYAN}==>${NC} %s\n" "$*"; }
die()  { fail "$*"; exit 1; }

[ "$(id -u)" = "0" ] || die "Run as root."
HOSTNAME_=$(hostname)
PRESEED="${1:-/tmp/preseed-worker.yaml}"
TARGET_USER="${SUDO_USER:-c4}"

[ -r "$PRESEED" ] || die "Preseed not readable: $PRESEED (pass path as arg 1, or scp to /tmp/preseed-worker.yaml)"

# ============================================================================
# Step 1/6: /dev/kvm present (UEFI Hypervisor Override is enabled)
# ============================================================================
step "Step 1/6: /dev/kvm present"
if [ -c /dev/kvm ]; then
  ok "/dev/kvm exists: $(ls -l /dev/kvm)"
  if dmesg 2>/dev/null | grep -q "CPU.*started at EL2"; then
    ok "Boot at EL2 confirmed (KVM hypervisor active)"
  fi
else
  fail "/dev/kvm not present — KVM is disabled at firmware level."
  echo "    Fix: reboot, press F2 during Qualcomm UEFI splash,"
  echo "    navigate Hypervisor Settings → Hypervisor Override → enable,"
  echo "    save & exit. Setting persists in UEFI NVRAM."
  exit 1
fi

# ============================================================================
# Step 2/6: Install Incus 7.0 + qemu + bridge-utils (idempotent)
#
# Default Armbian noble repos only ship Incus 6.0 (Ubuntu native). We use
# the Zabbly stable repo for Incus 7.0 — matches q6a-1's version exactly so
# the fleet has zero version drift. Key fingerprint verified against
# Stéphane Graber's published fingerprint to catch a swapped key.
# Repo: https://github.com/zabbly/incus
# ============================================================================
step "Step 2/6: install incus 7.0 (Zabbly repo) + qemu-system-arm + bridge-utils"
if dpkg -s incus >/dev/null 2>&1 && dpkg -s qemu-system-arm >/dev/null 2>&1; then
  ok "Already installed: $(incus --version 2>/dev/null | head -1)"
else
  warn "Setting up Zabbly Incus stable repo (if not already present) ..."
  install -d -m 0755 /etc/apt/keyrings
  if [ ! -f /etc/apt/keyrings/zabbly.asc ]; then
    curl -fsSL https://pkgs.zabbly.com/key.asc -o /etc/apt/keyrings/zabbly.asc
    chmod 0644 /etc/apt/keyrings/zabbly.asc
    FP=$(gpg --show-keys --with-colons /etc/apt/keyrings/zabbly.asc 2>/dev/null | awk -F: '/^fpr:/{print $10; exit}')
    EXPECTED="4EFC590696CB15B87C73A3AD82CC8797C838DCFD"
    [ "$FP" = "$EXPECTED" ] || die "Zabbly key fingerprint mismatch: got $FP, expected $EXPECTED"
    ok "Imported Zabbly key (fingerprint verified)"
  else
    ok "Zabbly key already present"
  fi
  if [ ! -f /etc/apt/sources.list.d/zabbly-incus-stable.sources ]; then
    cat > /etc/apt/sources.list.d/zabbly-incus-stable.sources <<'EOF'
Enabled: yes
Types: deb
URIs: https://pkgs.zabbly.com/incus/stable
Suites: noble
Components: main
Architectures: arm64
Signed-By: /etc/apt/keyrings/zabbly.asc
EOF
    ok "Wrote Zabbly Incus stable source"
  else
    ok "Zabbly source file already present"
  fi
  warn "Installing packages (a few minutes on first run) ..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq incus incus-ui-canonical qemu-system-arm qemu-utils bridge-utils >/dev/null
  ok "Installed: $(incus --version 2>/dev/null | head -1)"
fi

# ============================================================================
# Step 3/6: Add operator user to the incus-admin group (idempotent)
# ============================================================================
step "Step 3/6: add $TARGET_USER to incus-admin group"
if id -nG "$TARGET_USER" 2>/dev/null | tr ' ' '\n' | grep -qx incus-admin; then
  ok "$TARGET_USER already in incus-admin"
else
  usermod -aG incus-admin "$TARGET_USER"
  ok "Added $TARGET_USER to incus-admin (re-login needed for it to take effect)"
  warn "Re-login as $TARGET_USER (or run 'newgrp incus-admin') before using 'incus' without sudo."
fi

# ============================================================================
# Step 4/6: Apply preseed IFF Incus is not already initialized
# ============================================================================
step "Step 4/6: apply preseed (only if not already initialized)"
if incus storage list --format csv 2>/dev/null | grep -q .; then
  ok "Incus already initialized — preserving existing config"
  echo "    Current storage:"
  incus storage list --format compact 2>/dev/null | sed 's/^/      /'
else
  warn "Applying preseed from $PRESEED ..."
  incus admin init --preseed < "$PRESEED"
  ok "Preseed applied. Effective config (first 25 lines):"
  incus admin init --dump 2>/dev/null | head -25 | sed 's/^/      /'
fi

# ============================================================================
# Step 5/6: Verify daemon + API listener
#
# incus.service is socket-activated by incus.socket — it may briefly be
# "activating" right after `incus admin init` applies a new preseed.
# Check the always-on socket unit, then poll the API port with retry.
# ============================================================================
step "Step 5/6: verify incus daemon + :8443 listener"
if systemctl is-active --quiet incus.socket; then
  ok "incus.socket active (activates incus.service on demand)"
else
  die "incus.socket is not active — check 'journalctl -u incus.socket -n 80'"
fi
LISTENER_OK=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if ss -tln 2>/dev/null | grep -q ':8443'; then
    LISTENER_OK=1
    break
  fi
  sleep 1
done
if [ "$LISTENER_OK" = 1 ]; then
  ok ":8443 listening (HTTPS API + web UI)"
else
  warn ":8443 not listening after 10s — check 'sudo systemctl status incus' + 'incus config show'"
fi

# ============================================================================
# Step 6/6: Summary
# ============================================================================
step "Step 6/6: summary"
NODE_IP=$(ip -4 -br addr show enp1s0 2>/dev/null | awk '{print $3}' | cut -d/ -f1)
[ -n "$NODE_IP" ] || NODE_IP="<this-node-ip>"
ok "Incus is installed and ready on $HOSTNAME_."
echo "    Web UI: https://$NODE_IP:8443"
echo "    No VMs/containers running by default (dormant standby capacity)."
echo "    Re-login as $TARGET_USER (or 'newgrp incus-admin') to use 'incus' without sudo."
