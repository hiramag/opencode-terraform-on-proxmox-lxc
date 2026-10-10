output "containers" {
  description = "Map of hostname => { vm_id, ipv4, hostname }."
  value = {
    for name, ct in proxmox_virtual_environment_container.opencode : name => {
      vm_id    = ct.vm_id
      hostname = name
      ipv4     = try(ct.ipv4["eth0"], null)
    }
  }
}

output "hookscript_prestage_file" {
  description = "Local file to pre-stage on the PVE node before apply (see README: No-SSH deployment)."
  value       = local_file.hookscript.filename
}
