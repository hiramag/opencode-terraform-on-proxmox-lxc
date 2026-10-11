#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# deploy.sh — end-to-end deploy of the OpenCode LXC.
#
# Reproduces the manual runbook (README.md "Usage"):
#   1. tofu init / validate
#   2. render the hookscript locally            (local_file.hookscript)
#   3. pre-stage the hookscript on the PVE node (one scp — the documented
#      manual step; the deployment toolchain itself stays API-only)
#   4. tofu apply — creates the container; the bootstrap runs at post-start
#   5. verify OpenCode answers HTTP 200 on the container
#
# Secrets come from either source (tofu reads both automatically):
#   * terraform.tfvars            — written by ./configure.sh (recommended)
#   * TF_VAR_* environment vars   — TF_VAR_pve_password, TF_VAR_ct_root_password,
#                                   TF_VAR_opencode_password
#
# Optional overrides:
#   PVE_NODE=<host>                 Proxmox host for the snippet scp
#                                   (default: derived from pve_endpoint)
#   PVE_NODE_USER=root
#   SNIP_DIR=/var/lib/vz/snippets   dir backing the 'snippets' datastore
#   NO_SSH=1                        skip the scp; paste the snippet via the
#                                   Proxmox web console instead
#
# Gotchas baked in (learned during the build):
#   * always run from the repo — the script cd's there itself;
#   * never set TF_LOG=DEBUG/TRACE — it logs the API password in cleartext.
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_DIR"

PVE_NODE_USER="${PVE_NODE_USER:-root}"
SNIP_DIR="${SNIP_DIR:-/var/lib/vz/snippets}"
SNIPPET="opencode-hookscript.sh"

note() { printf '\n=== %s ===\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# read_tfvar <name> -> prints a simple string value from terraform.tfvars, if set
read_tfvar() {
  [ -f terraform.tfvars ] || return 1
  sed -nE "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"([^\"]*)\".*/\1/p" terraform.tfvars | head -1
}

# Proxmox host for the one-time snippet scp (step 3). Honour an explicit
# PVE_NODE, otherwise derive it from pve_endpoint in terraform.tfvars
# (https://10.10.10.8:8006/ -> 10.10.10.8). Unused when NO_SSH=1.
if [ -z "${PVE_NODE:-}" ]; then
  PVE_NODE="$(read_tfvar pve_endpoint 2>/dev/null | sed -E 's#^https?://##; s#[:/].*$##' || true)"
fi

# --- 0. preconditions ------------------------------------------------------
note "0. preconditions"
command -v tofu >/dev/null || die "tofu not found in PATH"
command -v curl >/dev/null || die "curl not found in PATH"

# Secrets may come from the environment (TF_VAR_*) or from terraform.tfvars.
if [ -f terraform.tfvars ]; then
  printf '  configuration: terraform.tfvars\n'
else
  printf '  configuration: TF_VAR_* environment variables\n'
fi
for v in pve_password ct_root_password opencode_password; do
  name="TF_VAR_$v"
  if [ -n "${!name:-}" ]; then
    printf '  %s: set (env)\n' "$name"
  elif [ -n "$(read_tfvar "$v" || true)" ]; then
    printf '  %s: from terraform.tfvars\n' "$v"
  else
    die "$name is unset and not in terraform.tfvars — run ./configure.sh or export it"
  fi
done

# The one-time snippet scp (step 3) needs the PVE password in the clear.
PVE_PW="${TF_VAR_pve_password:-$(read_tfvar pve_password || true)}"
[ -n "$PVE_PW" ] || die "could not determine pve_password (env or terraform.tfvars)"
if [ "${NO_SSH:-0}" != "1" ]; then
  command -v sshpass >/dev/null || die "sshpass not found (needed for the snippet scp); set NO_SSH=1 to paste by hand"
  [ -n "$PVE_NODE" ] || die "no Proxmox host: set PVE_NODE=<host> or add pve_endpoint to terraform.tfvars (or set NO_SSH=1)"
fi

# --- 1. init + validate (registry only, no node contact) -------------------
note "1. tofu init + validate"
tofu init -no-color
tofu validate -no-color

# --- 2. render the hookscript locally (no node contact) --------------------
note "2. render hookscript locally"
tofu apply -auto-approve -no-color -target=local_file.hookscript
[ -s "prestage/$SNIPPET" ] || die "prestage/$SNIPPET was not rendered"

# --- 3. pre-stage the hookscript on the node (one-time manual step) --------
note "3. pre-stage hookscript on the node"
if [ "${NO_SSH:-0}" = "1" ]; then
  printf '  NO_SSH=1: paste %s/prestage/%s onto the node as %s/%s (chmod 0700)\n' \
    "$REPO_DIR" "$SNIPPET" "$SNIP_DIR" "$SNIPPET"
  read -r -p "  press Enter when it is in place... " _
else
  export SSHPASS="$PVE_PW"   # keep the password out of argv (ps)
  sshpass -e ssh -o StrictHostKeyChecking=accept-new "$PVE_NODE_USER@$PVE_NODE" "mkdir -p '$SNIP_DIR'"
  sshpass -e scp -o StrictHostKeyChecking=accept-new "prestage/$SNIPPET" \
    "$PVE_NODE_USER@$PVE_NODE:$SNIP_DIR/$SNIPPET"
  sshpass -e ssh -o StrictHostKeyChecking=accept-new "$PVE_NODE_USER@$PVE_NODE" \
    "chmod 0700 '$SNIP_DIR/$SNIPPET'"
  unset SSHPASS
fi

# --- 4. deploy (API only) --------------------------------------------------
note "4. tofu apply (API only; bootstrap runs at post-start, ~60-90s cold)"
tofu apply -auto-approve -no-color

# --- 5. verify -------------------------------------------------------------
note "5. verify"
tofu output
IP="$(tofu output -json containers \
      | grep -oE '"ipv4"[[:space:]]*:[[:space:]]*"[^"]+"' \
      | head -1 | sed -E 's/.*"([^"]+)"$/\1/')"
[ -n "$IP" ] || die "could not determine the container IP from 'tofu output'"
printf '\nGET http://%s:4096/ ... ' "$IP"
code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "http://$IP:4096/" || true)"
printf 'HTTP %s\n' "$code"
[ "$code" = "200" ] || die "OpenCode did not answer 200 on http://$IP:4096/"

note "done — OpenCode is live at http://$IP:4096/"
printf 'Tear down with:  cd %s && tofu destroy\n' "$REPO_DIR"
