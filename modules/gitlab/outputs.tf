output "url" {
  description = "Browser URL for the GitLab UI."
  value       = "https://gitlab.${var.domain}"
}

output "registry_url" {
  value = "https://registry.${var.domain}"
}

output "namespace" {
  value = var.namespace
}

output "db_endpoint" {
  value     = aws_db_instance.this.address
  sensitive = true
}

output "redis_endpoint" {
  value     = aws_elasticache_replication_group.this.primary_endpoint_address
  sensitive = true
}

output "buckets" {
  description = "S3 buckets backing GitLab object storage, keyed by chart purpose."
  value       = local.bucket_names
}

output "s3_role_arn" {
  value = aws_iam_role.s3.arn
}

output "installed_by_terraform" {
  description = "False under install_method = \"helm\"; install-gitlab.sh refuses to run when this is true."
  value       = local.via_terraform
}

###############################################################################
# Consumed by helm-charts/bin/*.sh
#
# Grouped into one non-secret object and one sensitive object so a script can
# do a single `terraform output -json` and read fields out with jq, rather
# than the Helm side having to re-derive anything Terraform decided.
###############################################################################

output "helm_values" {
  description = "Non-secret substitutions for helm-charts/values/gitlab.values.yaml."
  value = {
    cluster_name  = var.cluster_name
    namespace     = var.namespace
    chart_version = var.chart_version
    aws_region    = var.aws_region

    domain     = var.domain
    acme_email = var.acme_email

    db_host     = aws_db_instance.this.address
    db_name     = local.db_name
    db_username = local.db_username

    redis_host = aws_elasticache_replication_group.this.primary_endpoint_address

    s3_role_arn = aws_iam_role.s3.arn
    buckets     = local.bucket_names

    node_selector_key   = "eks.amazonaws.com/nodegroup"
    node_selector_value = local.nodegroup_name

    webservice_replicas  = var.webservice_replicas
    sidekiq_replicas     = var.sidekiq_replicas
    gitaly_storage_size  = var.gitaly_storage_size
    gitaly_storage_class = var.gitaly_storage_class
    runner_helper_image  = var.runner_helper_image

    installed_by_terraform = local.via_terraform
  }
}

output "helm_secrets" {
  description = "Generated credentials, for the Kubernetes secrets the chart expects to already exist."
  sensitive   = true
  value = {
    db_password    = random_password.db.result
    redis_password = random_password.redis.result
  }
}
