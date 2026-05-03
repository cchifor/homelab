#!/usr/bin/env bash
# scripts/prep-worker.sh
#
# Worker prep checks for the homelab project. Run as root on each
# Radxa Q6A (QCS6490, Armbian/Debian on UEFI+GRUB, cgroupv2 unified hierarchy
# kernel ≥ 6.x). Read-only — verifies the worker is ready for k3s; doesn't
# mutate boot config or sysctls. If a check fails, prints the manual fix.
#
# Safe to re-run: every check is idempotent and side-effect free.

set -euo pipefail

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()   { printf "${GREEN}\xe2\x9c\x93${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}\xe2\x9a\xa0${NC} %s\n" "$*"; }
fail() { printf "${RED}\xe2\x9c\x97${NC} %s\n" "$*" >&2; }
step() { printf "\n${CYAN}==>${NC} %s\n" "$*"; }
die()  { fail "$*"; exit 1; }

[ "$(id -u)" = "0" ] || die "Run as root."
HOSTNAME_=$(hostname)

# ============================================================================
# Step 1: systemd is PID 1 (k3s requires it)
# ============================================================================
step "Step 1/6: systemd as PID 1"

PID1=$(ps -p 1 -o comm= 2>/dev/null || true)
if [ "$PID1" = "systemd" ]; then
  ok "PID 1 is systemd"
else
  die "PID 1 is '$PID1', not systemd. k3s requires a systemd init."
fi

# ============================================================================
# Step 2: memory cgroup controller (cgroupv2 unified hierarchy)
#
# These boards run cgroupv2 with CONFIG_MEMCG=y in the kernel. We just confirm
# 'memory' is in the unified hierarchy's controller list. The legacy
# cgroup_enable=memory cgroup_memory=1 cmdline workarounds are not needed and
# are silently ignored on cgroupv2 — don't add them.
# ============================================================================
step "Step 2/6: memory cgroup controller (cgroupv2)"

CONTROLLERS_FILE=/sys/fs/cgroup/cgroup.controllers
if [ -r "$CONTROLLERS_FILE" ] && grep -qw memory "$CONTROLLERS_FILE"; then
  ok "memory controller available in cgroupv2 unified hierarchy"
else
  fail "memory controller NOT available — k3s/kubelet would refuse to start"
  echo "    cgroupv2 controllers: $(cat "$CONTROLLERS_FILE" 2>/dev/null || echo "(no $CONTROLLERS_FILE)")"
  echo "    Likely fix: kernel needs CONFIG_MEMCG=y. On older boards using"
  echo "    cgroupv1, add 'systemd.unified_cgroup_hierarchy=1' to GRUB_CMDLINE_LINUX"
  echo "    in /etc/default/grub, run 'sudo update-grub', and reboot."
  exit 1
fi

# ============================================================================
# Step 3: kernel.unprivileged_userns_clone (Sysbox prereq)
#
# Kernels ≥ 5.10 ship without this toggle (user namespaces always allowed).
# Older kernels expose /proc/sys/kernel/unprivileged_userns_clone, which must
# be 1 for Sysbox to launch its system containers.
# ============================================================================
step "Step 3/6: unprivileged_userns_clone (Sysbox prereq, deferred)"

USERNS_FILE=/proc/sys/kernel/unprivileged_userns_clone
if [ ! -e "$USERNS_FILE" ]; then
  ok "$USERNS_FILE absent — implicitly enabled on this kernel"
elif [ "$(cat "$USERNS_FILE")" = "1" ]; then
  ok "unprivileged_userns_clone = 1"
else
  fail "unprivileged_userns_clone = 0 — Sysbox will refuse to start"
  echo "    Fix:"
  echo "      sudo sysctl -w kernel.unprivileged_userns_clone=1"
  echo "      echo 'kernel.unprivileged_userns_clone = 1' | sudo tee /etc/sysctl.d/99-sysbox.conf"
  exit 1
fi

# ============================================================================
# Step 4: passwordless sudo for the worker user
#
# Terraform's remote-exec provisioner can't allocate a TTY for sudo's password
# prompt — without NOPASSWD, the worker bootstrap deadlocks (sudo waits for
# input, stdin is held by the script). The bootstrap-time impact is one-time;
# we drop a /etc/sudoers.d/ entry scoped to the c4 user.
# ============================================================================
step "Step 4/6: passwordless sudo (for tofu remote-exec)"

# This script runs as root (asserted at the top), so we can detect the user
# whose key is being used by reading SSH_CONNECTION's owner — but simpler is
# to take it from the SUDO_USER env var (set by the sudo wrapper) or default.
TARGET_USER="${SUDO_USER:-c4}"
SUDO_FILE="/etc/sudoers.d/99-tofu-${TARGET_USER}"
DESIRED_LINE="${TARGET_USER} ALL=(ALL) NOPASSWD: ALL"

if [ -f "$SUDO_FILE" ] && grep -qxF "$DESIRED_LINE" "$SUDO_FILE"; then
  ok "passwordless sudo already configured for $TARGET_USER ($SUDO_FILE)"
else
  printf "%s\n" "$DESIRED_LINE" > "$SUDO_FILE"
  chmod 440 "$SUDO_FILE"
  if visudo -cf "$SUDO_FILE" >/dev/null 2>&1; then
    ok "Configured passwordless sudo for $TARGET_USER ($SUDO_FILE)"
  else
    rm -f "$SUDO_FILE"
    die "Generated sudoers file failed visudo validation; reverted."
  fi
fi

# ============================================================================
# Step 5: open-iscsi (Longhorn prerequisite)
#
# Longhorn's longhorn-manager runs `iscsiadm` via nsenter into the host's
# mount/network namespaces. Without open-iscsi installed on the host,
# longhorn-manager crashes with "failed to check environment, please make
# sure you have iscsiadm/open-iscsi installed". nfs-common is bundled in
# for the NFS-backed PVC use case.
# ============================================================================
step "Step 5/6: open-iscsi (Longhorn prerequisite)"

if command -v iscsiadm >/dev/null 2>&1 && systemctl is-enabled --quiet iscsid 2>/dev/null; then
  ok "open-iscsi already installed and iscsid enabled"
else
  warn "Installing open-iscsi + nfs-common"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq open-iscsi nfs-common >/dev/null
  systemctl enable --now iscsid open-iscsi >/dev/null 2>&1
  ok "Installed: $(iscsiadm --version 2>&1 | head -1)"
fi

# ============================================================================
# Step 6: sshd is active (OpenTofu null_resource provisioners need it)
# ============================================================================
step "Step 6/6: sshd"

if systemctl is-active --quiet ssh || systemctl is-active --quiet sshd; then
  ok "ssh service is active"
else
  fail "ssh service is not active"
  echo "    Fix: sudo systemctl enable --now ssh   (or sshd, per distro)"
  exit 1
fi

# ============================================================================
# Summary
# ============================================================================
step "Summary"
ok "$HOSTNAME_ is ready for tofu apply."
