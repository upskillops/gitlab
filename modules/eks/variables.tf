variable "cluster_name" { type = string }

variable "kubernetes_version" {
  description = "Control plane version. Leaving standard support moves the cluster to extended support at 6x the hourly rate."
  type        = string
}

variable "vpc_id" { type = string }
variable "subnet_ids" { type = list(string) }

variable "endpoint_public_access" {
  type    = bool
  default = true
}

variable "endpoint_public_access_cidrs" {
  type    = list(string)
  default = ["0.0.0.0/0"]
}

variable "enabled_log_types" {
  description = "Control plane log types. Each one is a CloudWatch log stream you pay for; audit is by far the largest."
  type        = list(string)
  default     = ["api", "audit", "authenticator"]
}

variable "tags" {
  type    = map(string)
  default = {}
}
