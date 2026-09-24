variable "cluster_name" { type = string }

variable "kubernetes_version" {
  description = "Needed to template nodeadm user data for AL2023."
  type        = string
}

variable "cluster_endpoint" { type = string }
variable "cluster_auth_base64" { type = string }
variable "cluster_service_cidr" { type = string }

variable "subnet_ids" { type = list(string) }
variable "node_security_group_id" { type = string }

variable "node_groups" {
  description = <<-EOT
    The guaranteed floor for each tier. Karpenter handles burst above these
    numbers via the matching NodePool.

    taint_workload = null leaves the group untainted (used by "core", which has
    to host CoreDNS / Cilium operator / Karpenter itself). Any other value
    applies workload=<value>:NoSchedule and the matching node label, so a
    tier's managed nodes and its Karpenter nodes are interchangeable to the
    scheduler.
  EOT
  type = map(object({
    instance_types = list(string)
    capacity_type  = optional(string, "ON_DEMAND")
    ami_type       = optional(string, "AL2023_ARM_64_STANDARD")
    min_size       = number
    max_size       = number
    desired_size   = number
    disk_size      = optional(number, 50)
    taint_workload = optional(string)
    extra_labels   = optional(map(string), {})
  }))
}

variable "cilium_is_cni" {
  description = "Whether Cilium is this cluster's CNI. False fails at plan: nothing else here installs one, so a joining node would have nothing to make it Ready."
  type        = bool
  default     = true
}

variable "create_timeout" {
  description = "Node group create timeout. Short when Terraform installs the CNI; long enough to cover a manual `helm install` when it does not."
  type        = string
  default     = "20m"
}

variable "tags" {
  type    = map(string)
  default = {}
}
