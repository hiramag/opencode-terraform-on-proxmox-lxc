provider "proxmox" {
  endpoint = var.pve_endpoint

  # Username/password auth as root@pam is REQUIRED (not the API token):
  # PVE only allows root@pam itself to set a container hookscript.
  username = var.pve_username
  password = var.pve_password

  # The Proxmox host uses a self-signed certificate.
  insecure = true

  # NO `ssh` block on purpose. The only provider operations that require
  # SSH are snippet uploads and container `idmap` entries -- neither is used
  # here, because the hookscript is pre-staged on the node instead. The provider
  # therefore talks to the Proxmox API only. (The one-time snippet copy is done
  # by deploy.sh over SSH, outside Terraform.)
}
