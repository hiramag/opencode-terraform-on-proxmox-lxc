#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# configure.sh — interactive wizard that writes terraform.tfvars.
#
# Asks only for what you actually have to know:
#   * the Proxmox connection (endpoint, node, root password)
#   * one container (hostname, IP, gateway, DNS)
#   * the two container/app passwords (or generate them for you)
# Every other variable keeps its default; the generated file leaves the
# advanced options commented so you can tweak them later by hand.
#
# It performs NO network actions and writes only terraform.tfvars (mode 0600),
# which is gitignored. Re-run it any time; it will offer to overwrite.
#
# It does NOT create anything on Proxmox — that is deploy.sh's job, which reads
# the terraform.tfvars this wizard writes.
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_DIR"

TFVARS="terraform.tfvars"
EXAMPLE="terraform.tfvars.example"

note() { printf '\n=== %s ===\n' "$*"; }
info() { printf '  %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# --- input helpers ---------------------------------------------------------

# ask <prompt> [default] -> prints the answer (default when blank)
ask() {
  local prompt="$1" default="${2:-}" reply
  if [ -n "$default" ]; then
    read -r -p "  $prompt [$default]: " reply
    printf '%s' "${reply:-$default}"
  else
    read -r -p "  $prompt: " reply
    printf '%s' "$reply"
  fi
}

# ask_secret <prompt> -> prints the answer without echoing it
ask_secret() {
  local prompt="$1" reply
  read -r -s -p "  $prompt: " reply
  printf '\n' >&2
  printf '%s' "$reply"
}

# ask_yn <prompt> -> success (0) for yes
ask_yn() {
  local reply
  read -r -p "  $1 [y/N]: " reply
  case "$reply" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

# --- validators ------------------------------------------------------------

valid_ipv4() {
  local ip="$1"; local -a octets
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -ra octets <<< "$ip"
  local n
  for n in "${octets[@]}"; do (( n <= 255 )) || return 1; done
  return 0
}

valid_hostname() {
  [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]]
}

# network address for <ip> <prefix>, e.g. 192.168.1.9 24 -> 192.168.1.0/24
lan_cidr_from() {
  local ip="$1" prefix="$2"; local -a oct
  IFS='.' read -ra oct <<< "$ip"
  local int=$(( (oct[0] << 24) + (oct[1] << 16) + (oct[2] << 8) + oct[3] ))
  local mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
  local net=$(( int & mask ))
  printf '%d.%d.%d.%d/%d' \
    $(( (net >> 24) & 255 )) $(( (net >> 16) & 255 )) \
    $(( (net >> 8) & 255 )) $(( net & 255 )) "$prefix"
}

gen_secret() { openssl rand -base64 18 2>/dev/null || head -c 24 /dev/urandom | base64; }

# escape a value for a double-quoted HCL string
hcl_escape() {
  local s="$1"
  s="${s//\\/\\\\}"        # backslash first
  s="${s//\"/\\\"}"        # double quote
  s="${s//'${'/'$${'}"     # defuse HCL interpolation
  printf '%s' "$s"
}

# --- 0. existing file? -----------------------------------------------------
if [ -e "$TFVARS" ]; then
  note "terraform.tfvars already exists"
  info "This wizard will OVERWRITE it (current secrets will be replaced)."
  if ! ask_yn "Overwrite?"; then
    info "aborted — existing $TFVARS left untouched."
    exit 0
  fi
  cp -p "$TFVARS" "$TFVARS.bak"
  chmod 600 "$TFVARS.bak"
  info "backup saved to $TFVARS.bak (mode 0600, gitignored)"
fi

# --- 1. Proxmox connection -------------------------------------------------
note "Proxmox connection"
info "Tip: find the node name in the PVE UI under Datacenter > <node>."
PVE_ENDPOINT="$(ask "PVE API endpoint URL" "https://192.168.1.8:8006/")"
PVE_NODE="$(ask "PVE node name" "proxdev")"
while :; do
  PVE_PASSWORD="$(ask_secret "PVE root password (auth as root@pam)")"
  [ -n "$PVE_PASSWORD" ] && break
  printf '  required — try again\n' >&2
done

# --- 2. the container ------------------------------------------------------
note "Container"
while :; do
  CT_HOST="$(ask "Hostname (becomes the container name)" "opencodev1")"
  valid_hostname "$CT_HOST" && break
  printf '  invalid — use letters, digits and hyphens (not starting/ending with -)\n' >&2
done

while :; do
  CT_IP="$(ask "Container IP address (e.g. 192.168.1.9)" "")"
  [ -n "$CT_IP" ] || { printf '  required\n' >&2; continue; }
  CT_IP="${CT_IP%%/*}"                 # tolerate a user typing a /prefix
  valid_ipv4 "$CT_IP" && break
  printf '  not a valid IPv4 address\n' >&2
done

CT_PREFIX="$(ask "Subnet prefix length" "24")"
if ! [[ "$CT_PREFIX" =~ ^[0-9]+$ ]] || (( CT_PREFIX < 1 )) || (( CT_PREFIX > 32 )); then
  info "invalid prefix — using 24"
  CT_PREFIX=24
fi

DEFAULT_GW="$(printf '%s' "$CT_IP" | awk -F. '{print $1"."$2"."$3".1"}')"
while :; do
  CT_GATEWAY="$(ask "Gateway" "$DEFAULT_GW")"
  valid_ipv4 "$CT_GATEWAY" && break
  printf '  not a valid IPv4 address\n' >&2
done

CT_DNS="$(ask "DNS server" "$CT_GATEWAY")"
if ! valid_ipv4 "$CT_DNS"; then
  info "invalid DNS — using the gateway"
  CT_DNS="$CT_GATEWAY"
fi

CT_IP_CIDR="$CT_IP/$CT_PREFIX"
LAN_CIDR="$(lan_cidr_from "$CT_IP" "$CT_PREFIX")"

# --- 3. passwords ----------------------------------------------------------
note "Passwords"
info "Press Enter to auto-generate (it will be shown once, below)."
CT_ROOT_PASSWORD="$(ask_secret "Container root password")"
GEN_ROOT=0
if [ -z "$CT_ROOT_PASSWORD" ]; then CT_ROOT_PASSWORD="$(gen_secret)"; GEN_ROOT=1; fi

OPENCODE_PASSWORD="$(ask_secret "OpenCode password")"
GEN_OC=0
if [ -z "$OPENCODE_PASSWORD" ]; then OPENCODE_PASSWORD="$(gen_secret)"; GEN_OC=1; fi

# --- 4. write terraform.tfvars --------------------------------------------
umask 077
{
  printf '# Generated by configure.sh on %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '# Holds secrets — this file is gitignored. Do not commit it.\n\n'

  printf 'pve_endpoint = "%s"\n' "$(hcl_escape "$PVE_ENDPOINT")"
  printf 'pve_node     = "%s"\n' "$(hcl_escape "$PVE_NODE")"
  printf '# pve_username = "root@pam"    # must stay root@pam (D-17)\n\n'

  printf 'containers = {\n'
  printf '  "%s" = {\n' "$CT_HOST"
  printf '    ip = "%s"\n' "$CT_IP_CIDR"
  cat <<'STATIC_CONTAINER'
    # cores         = 2
    # memory        = 4096        # MB
    # swap          = 512         # MB
    # projects_size = "5G"        # /projects volume — can grow, never shrink
  }
}

STATIC_CONTAINER

  printf 'ct_gateway = "%s"\n' "$(hcl_escape "$CT_GATEWAY")"
  printf 'ct_dns     = ["%s"]\n' "$(hcl_escape "$CT_DNS")"
  printf 'lan_cidr   = "%s"    # firewall allows this range to reach OpenCode\n\n' "$LAN_CIDR"

  cat <<'STATIC_ADVANCED'
# --- advanced (defaults shown; uncomment to change) ------------------------
# ct_bridge  = "vmbr0"
# ct_disk_datastore = "local-lvm"
# ct_disk_size      = 8
# snippets_datastore = "local"
# ct_template_file_id = "local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst"
# ct_unprivileged = true
# ct_on_boot      = true
# opencode_port   = 4096

STATIC_ADVANCED

  printf '# --- secrets ---------------------------------------------------------------\n'
  printf 'pve_password      = "%s"\n' "$(hcl_escape "$PVE_PASSWORD")"
  printf 'ct_root_password  = "%s"\n' "$(hcl_escape "$CT_ROOT_PASSWORD")"
  printf 'opencode_password = "%s"\n' "$(hcl_escape "$OPENCODE_PASSWORD")"
} > "$TFVARS"
chmod 600 "$TFVARS"

# --- 5. summary ------------------------------------------------------------
note "Wrote $REPO_DIR/$TFVARS (mode 0600)"
info "PVE       : $PVE_ENDPOINT   (node $PVE_NODE)"
info "container : $CT_HOST  ->  $CT_IP_CIDR"
info "gateway   : $CT_GATEWAY    DNS: $CT_DNS    LAN: $LAN_CIDR"
[ "$GEN_ROOT" = 1 ] && info "generated container root password: $CT_ROOT_PASSWORD"
[ "$GEN_OC"   = 1 ] && info "generated OpenCode password:       $OPENCODE_PASSWORD"

printf '\nNext:\n'
printf '  ./deploy.sh                 # full unattended deploy\n'
printf '  or: tofu init && tofu apply # and paste the snippet first (see README)\n'
printf '\nNote: keep the container IP OUTSIDE your router DHCP pool (see docs/plan.md).\n'
