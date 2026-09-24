variable "cluster_name" { type = string }
variable "aws_region" { type = string }
variable "vpc_id" { type = string }
variable "oidc_provider_arn" { type = string }

variable "oidc_provider" {
  description = "OIDC issuer host without the scheme, for the IRSA trust conditions."
  type        = string
}

variable "domain" {
  description = "Domain external-dns is allowed to write records in. Also the name of the hosted zone when create_route53_zone = true."
  type        = string
}

variable "create_route53_zone" {
  description = "Create the public hosted zone. False looks it up instead."
  type        = bool
  default     = true
}

variable "node_selector" {
  description = "Where both controllers run. They are cluster-wide plumbing, so they belong on the untainted core tier."
  type        = map(string)
  default     = { node-role = "core" }
}

variable "lbc_chart_version" {
  type    = string
  default = "3.5.0"
}

variable "external_dns_chart_version" {
  type    = string
  default = "1.15.2"
}

variable "tags" {
  type    = map(string)
  default = {}
}
