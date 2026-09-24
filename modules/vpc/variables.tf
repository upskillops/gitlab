variable "cluster_name" {
  description = "Names the VPC and is the value Karpenter's subnet discovery tag carries."
  type        = string
}

variable "cidr" { type = string }

variable "public_subnet_cidrs" {
  description = "One per AZ."
  type        = list(string)
}

variable "private_subnet_cidrs" {
  description = "One per AZ. All nodes live here. /20s because Cilium ENI mode gives every pod a real VPC IP, so pod density is bounded by subnet size, not by an overlay."
  type        = list(string)
}

variable "az_count" {
  type    = number
  default = 3
}

variable "single_nat_gateway" {
  description = "true = one shared NAT gateway (cheaper, not HA). false = one per AZ."
  type        = bool
  default     = false
}

variable "tags" {
  type    = map(string)
  default = {}
}
