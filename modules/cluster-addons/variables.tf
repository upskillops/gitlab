variable "cluster_name" {
  type = string
}

variable "enable_ebs_csi_driver" {
  description = "Install the EBS CSI driver addon. Without it nothing in the cluster can bind a PersistentVolumeClaim, and no StorageClasses are created either."
  type        = bool
  default     = true
}

variable "storage_classes" {
  description = "StorageClasses to create. Exactly one must set default = true. See the comment block in main.tf for why a class is not scoped to a node group."
  type = map(object({
    tier                   = optional(string)
    type                   = optional(string, "gp3")
    iops                   = optional(number)
    throughput             = optional(number)
    encrypted              = optional(bool, true)
    kms_key_id             = optional(string)
    reclaim_policy         = optional(string, "Delete")
    allow_volume_expansion = optional(bool, true)
    default                = optional(bool, false)
  }))
  default = {}

  validation {
    condition     = length(var.storage_classes) == 0 || length([for k, v in var.storage_classes : k if v.default]) == 1
    error_message = "Exactly one entry in storage_classes must set default = true."
  }

  validation {
    condition = alltrue([
      for k, v in var.storage_classes : contains(["Delete", "Retain"], v.reclaim_policy)
    ])
    error_message = "reclaim_policy must be \"Delete\" or \"Retain\"."
  }
}

variable "tags" {
  type    = map(string)
  default = {}
}
