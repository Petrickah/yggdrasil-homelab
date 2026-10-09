variable "node_name" {
    type        = string
    description = "Proxmox node the Virtual Machine is created on"
}

variable "vm_id" {
    type        = number
    description = "Virtual Machine ID used for when Proxmox creates the machine"
}

variable "hostname" {
    type = string
    description = "Virtual Machine Hostname used for when Proxmox creates the machine"
}

variable "cores" {
    type        = number
    description = "Virtual Machine CPU Cores used for when Proxmox creates the machine"
}

variable "memory" {
    type        = number
    description = "Virtual Machine Memory Capacity used for when Proxmox creates the machine"
}

variable "disk_size" {
    type        = number
    description = "Virtual Machine Disk Size used for when Proxmox creates the machine"
}

variable "disk_file" {
    type        = string
    description = "qcow2 in local:import that mk-qcow2.sh created for this host"

    validation {
        condition     = length(var.disk_file) > 0
        error_message = "No image for this host yet — run `bootstrap.py --host <hostname> image` first."
    }
}
