variable "pve_endpoint" {
  description = "Proxmox VE API endpoint URL."
  type        = string
  default     = "https://192.168.1.8:8006/"
}

variable "pve_username" {
  description = "Proxmox API username for username/password auth. Must resolve to 'root@pam' to assign a hookscript (D-17)."
  type        = string
  default     = "root@pam"
}

variable "pve_password" {
  description = "PVE host root password for pve_username (root@pam). Used for the Proxmox API connection only (D-19: the deployment needs no SSH). This is the ONE secret you must supply."
  type        = string
  sensitive   = true
}

variable "pve_node" {
  description = "Proxmox node name to deploy the containers on."
  type        = string
  default     = "proxdev"
}

variable "containers" {
  description = "Map of containers to create. Key = hostname (stable identity)."
  type = map(object({
    ip            = string
    cores         = optional(number, 2)
    memory        = optional(number, 4096)
    swap          = optional(number, 512)
    projects_size = optional(string, "5G")
  }))
  default = {
    opencodev1 = {
      ip = "192.168.1.9/24"
    }
  }
}

variable "ct_template_file_id" {
  description = "LXC template file ID used to create the container."
  type        = string
  default     = "local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst"
}

variable "ct_disk_datastore" {
  description = "Datastore for the container rootfs and the /projects volume."
  type        = string
  default     = "local-lvm"
}

variable "ct_disk_size" {
  description = "Root filesystem size in GB."
  type        = number
  default     = 8
}

variable "ct_bridge" {
  description = "Network bridge to attach the container to."
  type        = string
  default     = "vmbr0"
}

variable "ct_gateway" {
  description = "Default gateway for the container."
  type        = string
  default     = "192.168.1.1"
}

variable "ct_dns" {
  description = "DNS servers for the container."
  type        = list(string)
  default     = ["192.168.1.1"]
}

variable "ct_root_password" {
  description = "Root password for the container."
  type        = string
  sensitive   = true
}

variable "opencode_password" {
  description = "Password for the OpenCode service."
  type        = string
  sensitive   = true
}

variable "opencode_port" {
  description = "TCP port the OpenCode server listens on."
  type        = number
  default     = 4096
}

variable "lan_cidr" {
  description = "LAN CIDR allowed to reach the OpenCode port (nftables rule)."
  type        = string
  default     = "192.168.1.0/24"
}

variable "snippets_datastore" {
  description = "Datastore that allows 'snippets' content (hosts the hookscript)."
  type        = string
  default     = "local"
}

variable "ct_unprivileged" {
  description = "Run the container unprivileged."
  type        = bool
  default     = true
}

variable "ct_on_boot" {
  description = "Start the container automatically on host boot."
  type        = bool
  default     = true
}
