###############################################################################
# Cluster wiring -- supplied by the caller from the EKS/VPC modules
###############################################################################

variable "cluster_name" { type = string }
variable "aws_region" { type = string }
variable "vpc_id" { type = string }

variable "private_subnet_ids" {
  description = "Subnets for the RDS and ElastiCache subnet groups. Private: neither datastore is publicly accessible."
  type        = list(string)
}

variable "node_security_group_id" {
  description = "EKS node security group. The datastore security groups reference it rather than a CIDR, so only cluster nodes can connect."
  type        = string
}

variable "oidc_provider_arn" { type = string }

variable "oidc_provider" {
  description = "OIDC issuer host without the scheme, for the IRSA trust conditions."
  type        = string
}

###############################################################################
# GitLab itself
###############################################################################

variable "namespace" {
  type    = string
  default = "gitlab"
}

variable "domain" {
  description = "Base domain. The chart derives gitlab.<domain>, registry.<domain> and kas.<domain> from it."
  type        = string

  validation {
    condition     = trimspace(var.domain) != ""
    error_message = "domain must be set, e.g. \"example.com\". GitLab serves its UI at gitlab.<domain> and cannot be installed without one."
  }
}

variable "acme_email" {
  description = "Contact email for the Let's Encrypt account that issues GitLab's certificate."
  type        = string

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.acme_email))
    error_message = "acme_email must be a valid email address. Let's Encrypt requires it to register the ACME account."
  }
}

variable "install_method" {
  description = "\"terraform\" creates the namespace, secrets and helm_release here. \"helm\" provisions only the AWS side and leaves the rest to helm-charts/bin/install-gitlab.sh."
  type        = string
  default     = "helm"

  validation {
    condition     = contains(["helm", "terraform"], var.install_method)
    error_message = "install_method must be \"helm\" or \"terraform\"."
  }
}

variable "chart_version" {
  description = "GitLab Helm chart version. 10.4.0 = GitLab 19.4.0."
  type        = string
  default     = "10.4.0"
}

variable "wait_for_rollout" {
  description = "Block the apply until every GitLab pod is Ready. A first install runs migrations and pulls ~20 images, so this adds 10-20 minutes."
  type        = bool
  default     = false
}

variable "infra_nodegroup_name" {
  description = "Managed node group GitLab is pinned to. Null derives \"<cluster_name>-infra\"."
  type        = string
  default     = null
}

###############################################################################
# Datastores
###############################################################################

variable "db_instance_class" {
  type    = string
  default = "db.m7g.large"
}

variable "db_engine_version" {
  description = "Chart 10.x requires PostgreSQL 17 or newer -- 16 fails the migration job's version check."
  type        = string
  default     = "17.11"
}

variable "db_allocated_storage" {
  type    = number
  default = 100
}

variable "db_multi_az" {
  type    = bool
  default = false
}

variable "db_deletion_protection" {
  type    = bool
  default = false
}

variable "redis_node_type" {
  type    = string
  default = "cache.m7g.large"
}

variable "redis_engine_version" {
  type    = string
  default = "7.1"
}

###############################################################################
# Sizing
###############################################################################

variable "webservice_replicas" {
  type    = number
  default = 2
}

variable "sidekiq_replicas" {
  type    = number
  default = 2
}

variable "gitaly_storage_size" {
  type    = string
  default = "100Gi"
}

variable "gitaly_storage_class" {
  description = "StorageClass for Gitaly's repository volume. Should be one with reclaim_policy = Retain: this volume holds your git repositories."
  type        = string
  default     = "gp3-infra"
}

variable "runner_helper_image" {
  description = "Helper image for the Runner's Kubernetes executor. Published per-architecture rather than as a manifest list, so on Graviton it must carry the arm64- prefix or every CI job dies with \"exec format error\"."
  type        = string
  default     = "registry.gitlab.com/gitlab-org/gitlab-runner/gitlab-runner-helper:arm64-v19.3.2"
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "k8s_dependencies" {
  description = <<-EOT
    Opaque values from modules that must be applied before this module's
    Kubernetes resources -- the cluster addons and the ingress controllers.

    Passed as a value rather than expressed as `depends_on` on the module
    block, and that distinction is the point. A module-level `depends_on`
    applies to EVERY resource in the module, which pushed the RDS instance
    and the ElastiCache group -- neither of which needs Kubernetes at all --
    behind the whole cluster build. That put ~15 minutes of database creation
    on the critical path instead of running it alongside the control plane.

    Only the resources that genuinely need Kubernetes gate on this, via
    terraform_data.k8s_gate in release.tf.
  EOT
  type        = any
  default     = []
}
