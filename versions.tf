terraform {
  required_version = ">= 1.6.0"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.116"
    }
    # Renders the pre-staged hookscript to a local file (no SSH to the node).
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}
