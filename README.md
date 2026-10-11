# OpenCode LXC

A **single-layer OpenTofu** project that creates a Debian 12 **LXC container**
on Proxmox VE and fully configures a self-hosted **OpenCode v2** server — no
Ansible, no separate configuration phase.

The entire in-container configuration lives in one self-contained
`snippets/hookscript.sh.tftpl` (host hook **+** embedded bootstrap), which is
pre-staged on the node and run by Proxmox at container `post-start`.

## Usage

1. **`./configure.sh`** — interactive wizard. Asks for your PVE + container
   values and the passwords, then writes `terraform.tfvars`; it creates nothing
   and makes no network calls.
2. **`./deploy.sh`** — reads `terraform.tfvars` and builds the container end to
   end (`tofu init` → render → pre-stage → apply → verify).

> **Non-interactive:** `./deploy.sh` runs this whole flow (init → validate →
> render → pre-stage → apply → verify) unattended. It reads the same
> `TF_VAR_*` / `terraform.tfvars` inputs and aborts before any network action if
> a secret is missing. Set `NO_SSH=1` to pre-stage via the web console instead of
> the `scp` step. See the header comment in `deploy.sh` for overrides.

## Layout

```
.
├─ snippets/hookscript.sh.tftpl     # host hook + in-container bootstrap (rendered by TF)
├─ prestage/opencode-hookscript.sh  # rendered output to paste onto the node (gitignored)
├─ deploy.sh                        # non-interactive end-to-end run of the steps below
├─ configure.sh                     # interactive wizard that writes terraform.tfvars
├─ versions.tf / provider.tf / variables.tf / main.tf / outputs.tf
├─ .terraform.lock.hcl              # pinned provider versions + checksums (committed on purpose)
├─ terraform.tfvars.example
├─ LICENSE
└─ .gitignore / .gitattributes
```

One generated file is **deliberately kept in git**: `.terraform.lock.hcl`,
OpenTofu's dependency lock file. It records the exact provider versions
(`bpg/proxmox`, `hashicorp/local`) and their checksums that `tofu init`
installed, so every clone downloads the *same* provider builds and verifies
their integrity. Without it, `tofu init` would re-resolve the newest allowed
version on each run and could silently change behavior. It contains no secrets —
just versions and hashes.

## Prerequisites

- **Proxmox VE 8.x or 9.x** host reachable over HTTPS on `:8006`, and its
  **root password** (the provider authenticates the API as `root@pam` — API only).
- A rootfs datastore (`local-lvm`) and a template datastore (`local`).
- **`snippets` content enabled** on the snippet datastore —
  `pvesm set <store> --content vztmpl,backup,iso,snippets`.
- A Debian 12 LXC template (e.g. `local:vztmpl/debian-12-standard_*.tar.zst`).
- The container's static IP must be free and **outside the DHCP pool**.

## Secrets — what to supply, and where

**Everything goes in `terraform.tfvars`.** The easiest way to create it is the
wizard, which asks for the required values and derives the gateway/DNS/firewall
range for you:

```bash
./configure.sh
```

Prefer to do it by hand? `cp terraform.tfvars.example terraform.tfvars` and edit.

| Variable in `terraform.tfvars` | What it is | Who supplies it |
| --- | --- | --- |
| `pve_password` | PVE host **root password** — API auth as `root@pam` (API only; no SSH) | **You** — the *only* value you must provide |
| `ct_root_password` | Root password for the new container | You choose (or generate) |
| `opencode_password` | Password for the OpenCode service | You choose (or generate) |

> `pve_password` is the single **required** secret. The other two can be any
> value — generate them if you don't care:
> `openssl rand -base64 18`.

### Alternative: environment variables (nothing persisted to disk)

Any variable can be supplied as `TF_VAR_<name>` instead of editing
`terraform.tfvars`:

```bash
export TF_VAR_pve_password='<your PVE root password>'
export TF_VAR_ct_root_password="$(openssl rand -base64 18)"
export TF_VAR_opencode_password="$(openssl rand -base64 18)"
tofu apply
```

## Troubleshooting

| Symptom | Likely cause → fix |
| --- | --- |
| `template ... not found` / create fails on storage | Debian 12 template or datastore missing → download it (`pveam available` / `pveam download`) and check the datastore name |
| `changing the hookscript is only allowed for root@pam` | API **token** used → auth must be `root@pam` **password** |
| `storage 'local' does not support content type 'snippets'` | snippets not enabled → `pvesm set <store> --content vztmpl,backup,iso,snippets` |
| Container is up but `curl :4096` fails | bootstrap still running (cold ~60–90 s) or no internet from the CT → check `/var/log/opencode-bootstrap.log` inside it |
| Hook never runs on restart | idempotency marker `/root/.bootstrapped` is set; to re-run, edit the template → **re-render + re-paste** the snippet, then restart |
| Odd `lxc-attach` / `pct` failures from the hook | the hook runs on the node via `lxc-attach`; check `/var/log/opencode-bootstrap.log` in the container |
| A password showed up in a log | `TF_LOG=DEBUG/TRACE` was set → don't; rotate the password |

## Security considerations

Deliberate trade-offs — know them before exposing this to a network:

- **Root SSH with password** is enabled in the container
  (`PermitRootLogin yes`, `PasswordAuthentication yes`).
  For anything beyond a trusted LAN, switch to SSH keys and disable password
  auth in `snippets/hookscript.sh.tftpl`.
- **`OPENCODE_PASSWORD` is cleartext** in the systemd unit
  (`/etc/systemd/system/opencode.service`, world-readable). Prefer a mode-`0600`
  `EnvironmentFile` if that matters to you.
- **`pve_password`.** Keep `terraform.tfvars` `chmod 600`;
  never enable `TF_LOG`; and note that both it (as the API credential) and
  `ct_root_password` land in the OpenTofu **state** file in plaintext. Keep
  `terraform.tfstate` and `prestage/` root-only, and delete them when done.
- The container's **nftables** rule drops everything except `lan_cidr` →
  `:4096` and `:22`. Set `lan_cidr` to your real network.

## Teardown

`tofu destroy` removes the containers and their volumes. It does **not** remove
the pre-staged hookscript (OpenTofu does not manage it).

> For a stable deployment, add `lifecycle { prevent_destroy = true }` to the
> container resource (commented hint in `main.tf`).

## Secrets handling

`terraform.tfvars` is gitignored. Variable values (passwords) are stored in the
OpenTofu **state** file in plaintext, and `opencode_password` is embedded in the
gitignored `prestage/opencode-hookscript.sh` and in the node's snippet copy —
keep the state and `prestage/` root-only, and prefer the `TF_VAR_*` environment
variables when you don't want them persisted.

## License

MIT — see [`LICENSE`](LICENSE).
