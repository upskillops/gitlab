variable "cluster_name" { type = string }
variable "cluster_endpoint" { type = string }

variable "chart_version" { type = string }

variable "replicas" {
  description = "Controller replicas. The chart applies a *required* podAntiAffinity on hostname, so this many distinct core nodes must exist -- and because the release waits, the core group's desired_size must be at least this or the apply blocks on a Pending pod."
  type        = number
  default     = 2
}

variable "node_selector" {
  description = "Where the controller runs. Karpenter cannot manage the nodes it runs on, so this must be a pool it does not own."
  type        = map(string)
  default     = { node-role = "core" }
}

variable "tags" {
  type    = map(string)
  default = {}
}
