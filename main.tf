# ---------------------------------------------------------------------------
# Hookscript (pre-staged on the node, NOT uploaded by OpenTofu).
#
# The Proxmox API cannot write to a 'snippets' datastore, so the provider would
# need SSH purely to place this file. To keep the toolchain SSH-free, the
# hookscript is pre-staged on the node ONCE (via the Proxmox web console) and
# referenced by ID below. OpenTofu still renders the pasteable file locally so
# it stays in sync with the current variables.
#
# Pre-staging is a deliberate one-time manual step; see README.md
# ("No-SSH deployment").
# ---------------------------------------------------------------------------
locals {
  # Volume ID of the pre-staged hookscript (datastore:snippets/<filename>).
  hookscript_file_id = "${var.snippets_datastore}:snippets/opencode-hookscript.sh"

  # Rendered hookscript content (host hook + embedded in-container bootstrap).
  hookscript_content = templatefile("${path.module}/snippets/hookscript.sh.tftpl", {
    opencode_password = var.opencode_password
    opencode_port     = var.opencode_port
    lan_cidr          = var.lan_cidr
  })
}

# Materialise the hookscript locally so the operator can paste it into the PVE
# web console. Mode 0700 because Proxmox requires hook scripts to be executable.
# Gitignored: it embeds the OpenCode password.
resource "local_file" "hookscript" {
  filename        = "${path.module}/prestage/opencode-hookscript.sh"
  content         = local.hookscript_content
  file_permission = "0700"
}

# ---------------------------------------------------------------------------
# The containers.
# ---------------------------------------------------------------------------
resource "proxmox_virtual_environment_container" "opencode" {
  for_each = var.containers

  node_name     = var.pve_node
  unprivileged  = var.ct_unprivileged
  start_on_boot = var.ct_on_boot

  # NOTE: `vm_id` is intentionally omitted -> PVE assigns the next free ID.

  # Points at the pre-staged snippet (see above). Assigning it is a plain API
  # call -- no SSH.
  hook_script_file_id = local.hookscript_file_id

  initialization {
    hostname = each.key

    ip_config {
      ipv4 {
        address = each.value.ip
        gateway = var.ct_gateway
      }
    }

    dns {
      servers = var.ct_dns
    }

    user_account {
      password = var.ct_root_password
    }
  }

  cpu {
    cores = each.value.cores
  }

  memory {
    dedicated = each.value.memory
    swap      = each.value.swap
  }

  disk {
    datastore_id = var.ct_disk_datastore
    size         = var.ct_disk_size
  }

  # Dedicated persistent storage for OpenCode's project directory.
  mount_point {
    volume = var.ct_disk_datastore
    size   = each.value.projects_size
    path   = "/projects"
  }

  network_interface {
    name   = "eth0"
    bridge = var.ct_bridge
  }

  console {
    enabled = true
    type    = "tty"
  }

  operating_system {
    template_file_id = var.ct_template_file_id
    type             = "debian"
  }

  features {
    nesting = true
  }

  # Once the deployment is stable, consider adding:
  #   lifecycle { prevent_destroy = true }
}
