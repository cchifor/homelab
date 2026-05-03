#!/usr/bin/env bash
# scripts/check-prereqs.sh
#
# Idempotent operator-machine readiness check for the homelab project.
# Single invocation does everything: loads .env, prompts for the API token if
# missing (and persists it to .env), runs read-only checks against Proxmox + each
# worker, and generates terraform.tfvars on first run. Re-runs are no-ops once
# state is correct.
#
# Runs on Linux, macOS, and Windows (Git Bash, WSL, or Cygwin).
#
# Defaults assume the home-cluster topology (192.168.0.185 / .186 / .187 / .191-194).
# Override via env vars or flags — see "Defaults" block below.

set -uo pipefail   # no `-e` — we want to keep going past failed checks

# ============================================================================
# Source shared topology (single edit point: scripts/cluster.conf).
# CLI flags below still override anything cluster.conf sets.
# ============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_FILE="$SCRIPT_DIR/cluster.conf"
if [ ! -f "$CONF_FILE" ]; then
  printf "ERROR: %s not found.\n" "$CONF_FILE" >&2
  printf "       This file holds the cluster topology (PROXMOX_HOST, WORKERS, etc.).\n" >&2
  exit 2
fi
# shellcheck source=cluster.conf
. "$CONF_FILE"

# Script-local defaults (not shared cluster topology).
ENV_FILE="${ENV_FILE:-.env}"
TFVARS_FILE="${TFVARS_FILE:-terraform.tfvars}"

# CLI flags
while [ $# -gt 0 ]; do
  case "$1" in
    --proxmox-host)    PROXMOX_HOST="$2";        shift 2 ;;
    --proxmox-user)    PROXMOX_USER="$2";        shift 2 ;;
    --worker-user)     WORKER_USER="$2";         shift 2 ;;
    --ssh-key)         SSH_KEY_PATH="$2";        shift 2 ;;
    --ssh-pub-key)     SSH_PUBLIC_KEY_PATH="$2"; shift 2 ;;
    --env-file)        ENV_FILE="$2";            shift 2 ;;
    --tfvars-file)     TFVARS_FILE="$2";         shift 2 ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
      exit 0 ;;
    *) printf "Unknown argument: %s\n" "$1" >&2; exit 2 ;;
  esac
done

# ============================================================================
# Output helpers
# ============================================================================
if [ -t 1 ]; then
  GREEN=$'\e[0;32m'; RED=$'\e[0;31m'; YELLOW=$'\e[0;33m'
  CYAN=$'\e[0;36m';  GRAY=$'\e[0;90m'; NC=$'\e[0m'
else
  GREEN=''; RED=''; YELLOW=''; CYAN=''; GRAY=''; NC=''
fi

PASS=0; WARN=0; FAIL=0
BLOCKERS=()

ok()    { printf "  ${GREEN}[PASS]${NC} %s\n" "$*"; PASS=$((PASS+1)); }
warn()  { printf "  ${YELLOW}[WARN]${NC} %s\n" "$*"; WARN=$((WARN+1)); }
fail()  { printf "  ${RED}[FAIL]${NC} %s\n" "$*"; FAIL=$((FAIL+1)); BLOCKERS+=("$*"); }
step()  { printf "\n${CYAN}==>${NC} %s\n" "$*"; }

# ============================================================================
# Helpers
# ============================================================================

# Load KEY=VALUE pairs from a .env-style file into the env. Doesn't override
# values already set in the shell (shell wins).
load_env() {
  local f="$1"
  [ -f "$f" ] || return 1
  local line key val
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    if [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      val="${BASH_REMATCH[2]}"
      # Strip surrounding quotes if present.
      [[ "$val" == \"*\" ]] && val="${val:1:${#val}-2}"
      [[ "$val" == \'*\' ]] && val="${val:1:${#val}-2}"
      if [ -n "$val" ] && [ -z "${!key:-}" ]; then
        export "$key=$val"
      fi
    fi
  done < "$f"
  return 0
}

# Run a command via ssh; returns exit code, prints output to stdout.
ssh_run() {
  local user="$1"; local host="$2"; local cmd="$3"
  ssh -o StrictHostKeyChecking=accept-new \
      -o ConnectTimeout=8 \
      -o BatchMode=yes \
      -i "$SSH_KEY_PATH" \
      "$user@$host" "$cmd" 2>&1
}

# Convert a path to its tilde-relative form (if under $HOME) for HCL output.
hcl_path() {
  local p="$1"
  if [[ "$p" == "$HOME"* ]]; then
    p="~${p#$HOME}"
  fi
  # Normalize Git-Bash-on-Windows /c/... paths to C:/... so terraform on Windows likes them.
  if [[ "$p" =~ ^/([a-zA-Z])/(.*)$ ]]; then
    p="${BASH_REMATCH[1]^^}:/${BASH_REMATCH[2]}"
  fi
  printf '"%s"' "$p"
}

# Quote a string for HCL.
hcl_string() {
  local s="${1:-}"
  s="${s//\\/\\\\}"   # escape backslashes
  s="${s//\"/\\\"}"   # escape quotes
  printf '"%s"' "$s"
}

# Discovered values populated during checks; used for tfvars generation.
DISCOVERED_ALPINE_TEMPLATE=""
DISCOVERED_CP_TEMPLATE_NAME=""
DISCOVERED_PM_NODE_NAME=""

# ============================================================================
# 1. Load .env (best-effort, BEFORE the env-var checks)
# ============================================================================
ENV_FILE_ABS="$ENV_FILE"
[[ "$ENV_FILE_ABS" == /* || "$ENV_FILE_ABS" =~ ^[a-zA-Z]: ]] || ENV_FILE_ABS="$PWD/$ENV_FILE_ABS"

if load_env "$ENV_FILE_ABS"; then
  printf "${GRAY}(loaded env vars from %s)${NC}\n" "$ENV_FILE_ABS"
fi

# ============================================================================
# 2. Operator machine
# ============================================================================
step "Operator machine"

# IaC binary: prefer tofu, fall back to terraform.
if command -v tofu >/dev/null 2>&1; then
  ok "tofu found: $(tofu version 2>/dev/null | head -1)  ($(command -v tofu))"
elif command -v terraform >/dev/null 2>&1; then
  ok "terraform found: $(terraform version 2>/dev/null | head -1)  ($(command -v terraform))"
else
  fail "Neither 'tofu' nor 'terraform' on PATH."
fi

# ssh client
if command -v ssh >/dev/null 2>&1; then
  ok "ssh client: $(command -v ssh)"
else
  fail "ssh client not on PATH. (Windows: install OpenSSH client via Settings > Optional Features.)"
fi

# SSH private key
if [ -f "$SSH_KEY_PATH" ]; then
  ok "SSH private key present: $SSH_KEY_PATH"
else
  fail "SSH private key not found at $SSH_KEY_PATH"
fi

# SSH public key (used for cp_ssh_public_key in tfvars)
if [ -f "$SSH_PUBLIC_KEY_PATH" ]; then
  ok "SSH public key present: $SSH_PUBLIC_KEY_PATH"
else
  warn "SSH public key not found at $SSH_PUBLIC_KEY_PATH (cp_ssh_public_key in tfvars will be a placeholder until you fix it)"
fi

# Optional verification tools
for tool in kubectl helm mc; do
  if command -v "$tool" >/dev/null 2>&1; then
    ok "$tool found: $(command -v "$tool")  (post-apply verification)"
  else
    warn "$tool not on PATH (optional; useful for post-apply verification)"
  fi
done

# ============================================================================
# 3. API token: ensure it's set, prompt + persist if not
# ============================================================================
step "Proxmox API token (TF_VAR_pm_api_token_secret)"

if [ -n "${TF_VAR_pm_api_token_secret:-}" ]; then
  printf "  ${GREEN}[PASS]${NC} TF_VAR_pm_api_token_secret is set (%d chars, value not displayed)\n" \
    "${#TF_VAR_pm_api_token_secret}"
  PASS=$((PASS+1))
else
  printf "  Not set in shell or in %s.\n" "$ENV_FILE_ABS"
  printf "  Paste the 'value' field from prep-proxmox.sh below (input is hidden):\n  "
  read -r -s TOKEN
  printf "\n"
  if [ -z "$TOKEN" ]; then
    fail "No token provided — cannot continue."
  else
    export TF_VAR_pm_api_token_secret="$TOKEN"
    # Persist to .env (create or update).
    if [ -f "$ENV_FILE_ABS" ]; then
      if grep -q '^TF_VAR_pm_api_token_secret=' "$ENV_FILE_ABS"; then
        # In-place edit (portable: write to temp, then replace).
        tmp=$(mktemp); awk -v val="$TOKEN" \
          '/^TF_VAR_pm_api_token_secret=/{print "TF_VAR_pm_api_token_secret=" val; next} {print}' \
          "$ENV_FILE_ABS" > "$tmp" && mv "$tmp" "$ENV_FILE_ABS"
      else
        printf 'TF_VAR_pm_api_token_secret=%s\n' "$TOKEN" >> "$ENV_FILE_ABS"
      fi
    else
      cat > "$ENV_FILE_ABS" <<EOF
# homelab/.env  (gitignored)
# Loaded by scripts/check-prereqs.sh; only sets vars not already in the shell.
TF_VAR_pm_api_token_secret=$TOKEN

# Optional — pins the initial Rancher admin password (auto-generated if blank).
# TF_VAR_rancher_bootstrap_password=
EOF
    fi
    chmod 600 "$ENV_FILE_ABS" 2>/dev/null || true
    ok "Token captured and persisted to $ENV_FILE_ABS"
  fi
fi

# ============================================================================
# 4. Proxmox host
# ============================================================================
step "Proxmox host ($PROXMOX_HOST)"

PM_REACHABLE=0
out=$(ssh_run "$PROXMOX_USER" "$PROXMOX_HOST" 'hostname')
if [ $? -ne 0 ]; then
  fail "SSH ${PROXMOX_USER}@${PROXMOX_HOST} failed: ${out}"
else
  PM_REACHABLE=1
  DISCOVERED_PM_NODE_NAME=$(printf '%s' "$out" | tr -d '\r' | head -1)
  ok "SSH ${PROXMOX_USER}@${PROXMOX_HOST} OK (hostname: $DISCOVERED_PM_NODE_NAME)"
fi

if [ "$PM_REACHABLE" = "1" ]; then
  # Tooling check
  out=$(ssh_run "$PROXMOX_USER" "$PROXMOX_HOST" 'command -v pveum && command -v qm && command -v pveam')
  if [ $? -eq 0 ]; then
    ok "pveum / qm / pveam all present"
  else
    fail "Proxmox tools missing — is this actually a Proxmox VE host?"
  fi

  # Token
  out=$(ssh_run "$PROXMOX_USER" "$PROXMOX_HOST" \
    "pveum user token list 'tofu-prov@pve' --noborder --noheader 2>/dev/null | awk '{print \$1}' | grep -qx tofu-token && echo HAS_TOKEN || echo NO_TOKEN")
  if [ "$(printf '%s' "$out" | tr -d '\r' | head -1)" = "HAS_TOKEN" ]; then
    ok "API token exists on Proxmox: $TOFU_TOKEN_ID_HINT"
  else
    fail "API token '$TOFU_TOKEN_ID_HINT' not found — run scripts/prep-proxmox.sh on the Proxmox host."
  fi

  # Alpine template
  out=$(ssh_run "$PROXMOX_USER" "$PROXMOX_HOST" \
    "pveam list local 2>/dev/null | awk '{print \$1}' | awk -F/ '{print \$NF}' | grep -E '^alpine-3\.[0-9]+-default_.*_amd64\.tar\.xz$' | sort | tail -1")
  out=$(printf '%s' "$out" | tr -d '\r' | head -1)
  if [ -z "$out" ]; then
    fail "No Alpine LXC template on storage 'local' — run scripts/prep-proxmox.sh."
  else
    DISCOVERED_ALPINE_TEMPLATE="$out"
    ok "Alpine template present: $DISCOVERED_ALPINE_TEMPLATE"
  fi

  # Debian template VM (VMID 9000)
  out=$(ssh_run "$PROXMOX_USER" "$PROXMOX_HOST" \
    'qm config 9000 2>/dev/null | grep -E "^(name|template):" || echo NO_VM')
  if [[ "$out" == *NO_VM* ]]; then
    fail "VMID 9000 does not exist — run scripts/prep-proxmox.sh."
  elif [[ "$out" == *"template: 1"* ]] && [[ "$out" =~ name:[[:space:]]+([^[:space:]$'\r']+) ]]; then
    DISCOVERED_CP_TEMPLATE_NAME="${BASH_REMATCH[1]}"
    ok "Debian template VM 9000 exists and is a template (name: $DISCOVERED_CP_TEMPLATE_NAME)"
  else
    warn "VMID 9000 exists but is not marked as a template (or check failed)."
  fi

  # bond0 LACP / mode
  out=$(ssh_run "$PROXMOX_USER" "$PROXMOX_HOST" \
    '[ -r /proc/net/bonding/bond0 ] && cat /proc/net/bonding/bond0 || echo NO_BOND')
  if [[ "$out" == *NO_BOND* ]]; then
    warn "No /proc/net/bonding/bond0 — bond not configured."
  else
    mode=$(printf '%s' "$out" | awk -F': ' '/Bonding Mode/{print $2; exit}' | tr -d '\r')
    ports=$(printf '%s' "$out" | awk '/Number of ports:/{print $4; exit}' | tr -d '\r')
    partner=$(printf '%s' "$out" | awk '/Partner Mac Address/{print $4; exit}' | tr -d '\r')
    if [[ "$mode" == *"active-backup"* ]]; then
      ok "bond0: active-backup mode (no switch-side LAG needed)"
    elif [ "$ports" = "2" ] && [ -n "$partner" ] && [ "$partner" != "00:00:00:00:00:00" ]; then
      ok "bond0: LACP synchronized (mode='$mode', ports=$ports, partner=$partner)"
    else
      fail "bond0 LACP NOT synchronized (mode='$mode', ports=$ports, partner=$partner) — configure UniFi LAG (README §3)."
    fi
  fi
fi

# ============================================================================
# 5. Workers
# ============================================================================
# Read into an array first so the loop body keeps stdin = terminal.
# (See the same pattern + rationale in deploy-prep.sh — a `while ... <<<`
# would redirect stdin to the WORKERS string and break any interactive
# prompts inside the loop, current or future.)
mapfile -t WORKER_LINES <<< "$WORKERS"
for entry in "${WORKER_LINES[@]}"; do
  [ -n "$entry" ] || continue
  IFS='=' read -r wname waddr <<< "$entry"
  step "Worker $wname ($waddr)"

  out=$(ssh_run "$WORKER_USER" "$waddr" 'hostname')
  if [ $? -ne 0 ]; then
    fail "$wname: SSH ${WORKER_USER}@${waddr} failed: ${out}"
    continue
  fi
  ok "SSH ${WORKER_USER}@${waddr} OK"

  out=$(ssh_run "$WORKER_USER" "$waddr" 'ps -p 1 -o comm=')
  out=$(printf '%s' "$out" | tr -d '\r' | head -1)
  if [ "$out" = "systemd" ]; then
    ok "systemd is PID 1"
  else
    fail "$wname: PID 1 is '$out', not systemd."
  fi

  # cgroupv2 first (the modern path on these boards); fall back to cgroupv1.
  out=$(ssh_run "$WORKER_USER" "$waddr" '
    if [ -r /sys/fs/cgroup/cgroup.controllers ] && grep -qw memory /sys/fs/cgroup/cgroup.controllers; then
      echo "OK_V2"
    elif [ -r /proc/cgroups ] && awk "\$1==\"memory\" && \$4==\"1\" {found=1} END {exit !found}" /proc/cgroups; then
      echo "OK_V1"
    else
      echo "NOT_OK"
    fi')
  out=$(printf '%s' "$out" | tr -d '\r' | head -1)
  case "$out" in
    OK_V2) ok "memory cgroup controller available (cgroupv2)" ;;
    OK_V1) ok "memory cgroup controller enabled (cgroupv1)" ;;
    *)     fail "$wname: memory cgroup controller NOT available — run scripts/prep-worker.sh for the manual fix." ;;
  esac

  out=$(ssh_run "$WORKER_USER" "$waddr" \
    'cat /proc/sys/kernel/unprivileged_userns_clone 2>/dev/null || echo MISSING')
  out=$(printf '%s' "$out" | tr -d '\r' | head -1)
  if [ "$out" = "1" ] || [ "$out" = "MISSING" ]; then
    ok "unprivileged_userns_clone OK ($out)"
  else
    fail "$wname: unprivileged_userns_clone = $out — run scripts/prep-worker.sh."
  fi
done

# ============================================================================
# 6. Generate terraform.tfvars if missing
# ============================================================================
TFVARS_ABS="$TFVARS_FILE"
[[ "$TFVARS_ABS" == /* || "$TFVARS_ABS" =~ ^[a-zA-Z]: ]] || TFVARS_ABS="$PWD/$TFVARS_ABS"

if [ -f "$TFVARS_ABS" ]; then
  step "terraform.tfvars"
  ok "$TFVARS_ABS exists — left as-is (delete it and re-run to regenerate from current discovery)"
else
  step "Generating terraform.tfvars"

  # Public-key content (or a placeholder if missing)
  pubkey_content=""
  if [ -f "$SSH_PUBLIC_KEY_PATH" ]; then
    pubkey_content=$(tr -d '\r' < "$SSH_PUBLIC_KEY_PATH" | head -1)
  fi

  # Resolved HCL fragments (graceful fallbacks if discovery missed something).
  if [ -n "$DISCOVERED_ALPINE_TEMPLATE" ]; then
    nas_template_line="nas_template     = \"local:vztmpl/${DISCOVERED_ALPINE_TEMPLATE}\""
  else
    nas_template_line="# nas_template     = \"local:vztmpl/alpine-3.23-default_<datestamp>_amd64.tar.xz\"  # NOT DISCOVERED — fill after prep-proxmox.sh"
  fi
  if [ -n "$DISCOVERED_CP_TEMPLATE_NAME" ]; then
    cp_template_line="cp_template_name = \"${DISCOVERED_CP_TEMPLATE_NAME}\""
  else
    cp_template_line="# cp_template_name = \"debian-12-cloudinit-template\"  # NOT DISCOVERED — fill after prep-proxmox.sh"
  fi
  if [ -n "$DISCOVERED_PM_NODE_NAME" ]; then
    pm_node_line="pm_node_name    = \"${DISCOVERED_PM_NODE_NAME}\""
  else
    pm_node_line="# pm_node_name    = \"pve\"  # NOT DISCOVERED"
  fi
  if [ -n "$pubkey_content" ]; then
    cp_pubkey_line="cp_ssh_public_key       = $(hcl_string "$pubkey_content")"
  else
    cp_pubkey_line="# cp_ssh_public_key       = \"ssh-ed25519 AAAA... your-key-here\"  # ${SSH_PUBLIC_KEY_PATH} NOT FOUND"
  fi

  ssh_key_hcl=$(hcl_path "$SSH_KEY_PATH")

  {
    printf "# Generated by scripts/check-prereqs.sh on %s\n" "$(date -Iseconds 2>/dev/null || date)"
    printf "# Hand-edit anything below; this file is NOT regenerated unless you delete it and re-run.\n"
    printf "\n"
    printf "# --- Operator-side SSH (used by null_resource provisioners) ---\n"
    printf "proxmox_host_address              = %s\n" "$(hcl_string "$PROXMOX_HOST")"
    printf "proxmox_host_ssh_user             = %s\n" "$(hcl_string "$PROXMOX_USER")"
    printf "proxmox_host_ssh_private_key_path = %s\n" "$ssh_key_hcl"
    printf "\n"
    printf "# --- Proxmox API auth (secret comes from \$env:TF_VAR_pm_api_token_secret via .env) ---\n"
    printf "pm_api_url      = \"https://%s:8006/api2/json\"\n" "$PROXMOX_HOST"
    printf "pm_api_token_id = %s\n" "$(hcl_string "$TOFU_TOKEN_ID_HINT")"
    printf "pm_tls_insecure = true\n"
    printf "%s\n" "$pm_node_line"
    printf "\n"
    printf "# --- Network ---\n"
    printf "lan_cidr    = \"192.168.0.0/24\"\n"
    printf "lan_gateway = \"192.168.0.1\"\n"
    printf "lan_dns     = [\"192.168.0.1\", \"1.1.1.1\"]\n"
    printf "bridge      = \"vmbr0\"\n"
    printf "mtu         = 1500\n"
    printf "\n"
    printf "# --- NAS LXC ---\n"
    printf "%s\n" "$nas_template_line"
    printf "\n"
    printf "# --- Control-plane VM ---\n"
    printf "%s\n" "$cp_template_line"
    printf "%s\n" "$cp_pubkey_line"
    printf "cp_ssh_private_key_path = %s\n" "$ssh_key_hcl"
    printf "cp_ssh_user             = \"debian\"\n"
    printf "\n"
    printf "# --- Workers ---\n"
    printf "workers = {\n"
    while IFS='=' read -r wname waddr; do
      [ -n "$wname" ] || continue
      printf '  "%s" = { name = "%s", address = "%s", ssh_user = "%s", ssh_key = %s }\n' \
        "$wname" "$wname" "$waddr" "$WORKER_USER" "$ssh_key_hcl"
    done <<< "$WORKERS"
    printf "}\n"
  } > "$TFVARS_ABS"

  ok "Wrote $TFVARS_ABS"
fi

# ============================================================================
# 7. Summary
# ============================================================================
step "Summary"
printf "  Pass: %d   Warn: %d   Fail: %d\n\n" "$PASS" "$WARN" "$FAIL"

if [ "$FAIL" -eq 0 ]; then
  printf "${GREEN}Ready.${NC}\n"
  printf "  cd %s\n" "$PWD"
  printf "  terraform init\n"
  printf "  # then the two-phase first apply per README §\"First apply\"\n"
  exit 0
else
  printf "${RED}Blockers (fix these before terraform apply):${NC}\n"
  i=1
  for b in "${BLOCKERS[@]}"; do
    printf "  %d. %s\n" "$i" "$b"
    i=$((i+1))
  done
  exit 1
fi
