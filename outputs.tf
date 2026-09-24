###############################################################################
# Cluster
###############################################################################

output "cluster_name" {
  value = local.cluster_name
}

output "cluster_endpoint" {
  value = local.cluster_endpoint
}

output "configure_kubectl" {
  value = "aws eks update-kubeconfig --name ${local.cluster_name} --region ${var.aws_region}"
}

output "vpc_id" {
  value = var.create_cluster ? module.vpc[0].vpc_id : null
}

output "private_subnet_ids" {
  value = var.create_cluster ? module.vpc[0].private_subnets : null
}

###############################################################################
# Compute
###############################################################################

output "node_groups" {
  description = "Graviton managed node groups providing each tier's guaranteed floor."
  value = var.create_cluster ? {
    for k, id in module.nodegroups[0].groups : k => {
      name           = id
      instance_types = var.workload_node_groups[k].instance_types
      min_size       = var.workload_node_groups[k].min_size
      max_size       = var.workload_node_groups[k].max_size
      taint          = var.workload_node_groups[k].taint_workload == null ? "none (untainted)" : "workload=${var.workload_node_groups[k].taint_workload}:NoSchedule"
    }
  } : null
}

output "karpenter_nodepools" {
  description = "Karpenter NodePools providing burst above the floors."
  value       = { for k, m in module.nodepool : k => m.taint }
}

output "karpenter_node_role_name" {
  description = "IAM role Karpenter uses for the instances it launches."
  value       = local.node_iam_role_name
}

output "nodegroup_node_role_name" {
  description = "IAM role shared by the managed node groups."
  value       = one(module.nodegroups[*].node_iam_role_name)
}

###############################################################################
# Cilium
###############################################################################

output "cilium_operator_role_arn" {
  description = "IRSA role the Cilium operator assumes to manage ENIs."
  value       = one(module.cilium[*].operator_role_arn)
}

output "verify_cilium" {
  description = "Confirm Cilium fully replaced VPC CNI and kube-proxy."
  value       = "kubectl -n kube-system get ds cilium && kubectl -n kube-system get ds aws-node kube-proxy 2>&1 | tail -1"
}

###############################################################################
# Storage
###############################################################################

output "storage_classes" {
  description = "StorageClasses created, and which one is default."
  value = var.create_cluster ? {
    names   = one(module.cluster_addons[*].storage_class_names)
    default = one(module.cluster_addons[*].default_storage_class)
  } : null
}

###############################################################################
# GitLab
###############################################################################

output "gitlab_url" {
  description = "Browser URL for the GitLab UI."
  value       = one(module.gitlab[*].url)
}

output "gitlab_registry_url" {
  value = one(module.gitlab[*].registry_url)
}

output "gitlab_root_password_command" {
  description = "Retrieve the initial root password (rotate it after first login)."
  value = local.gitlab_enabled ? join(" ", [
    "kubectl -n ${var.gitlab_namespace} get secret gitlab-gitlab-initial-root-password",
    "-o jsonpath='{.data.password}' | base64 -d; echo",
  ]) : null
}

output "gitlab_nameservers" {
  description = "Delegate gitlab_domain to these at your registrar. Until this is done the UI will not resolve and Let's Encrypt cannot issue a certificate."
  value       = try(one(module.ingress[*].route53_zone_nameservers), [])
}

output "gitlab_db_endpoint" {
  value     = one(module.gitlab[*].db_endpoint)
  sensitive = true
}

output "gitlab_redis_endpoint" {
  value     = one(module.gitlab[*].redis_endpoint)
  sensitive = true
}

output "gitlab_buckets" {
  description = "S3 buckets backing GitLab object storage."
  value       = try(one(module.gitlab[*].buckets), {})
}

output "gitlab_watch_rollout" {
  description = "GitLab installs asynchronously by default; follow it with this."
  value       = local.gitlab_enabled ? "kubectl -n ${var.gitlab_namespace} get pods -w" : null
}

###############################################################################
# Consumed by ../helm-charts/bin/*.sh
#
# These names are an interface -- the install scripts read them by name with
# `terraform output -json`. Renaming one breaks the scripts silently.
###############################################################################

output "helm_cilium_values" {
  description = "Substitutions for helm-charts/values/cilium.values.yaml."
  value = local.install_cilium ? {
    cluster_name           = local.cluster_name
    chart_version          = var.cilium_version
    k8s_service_host       = module.cilium[0].k8s_service_host
    vpc_cidr               = var.vpc_cidr
    operator_role_arn      = module.cilium[0].operator_role_arn
    operator_replicas      = var.cilium_operator_replicas
    prefix_delegation      = var.cilium_enable_prefix_delegation
    hubble_relay           = var.cilium_enable_hubble_relay
    installed_by_terraform = module.cilium[0].installed_by_terraform
  } : null
}

output "helm_gitlab_values" {
  description = "Non-secret substitutions for helm-charts/values/gitlab.values.yaml."
  value       = one(module.gitlab[*].helm_values)
}

# Kept separate and marked sensitive so `terraform output` stays readable and
# the values never land in a shell trace. install-gitlab.sh pipes these
# straight into `kubectl create secret` without writing them to disk.
output "helm_gitlab_secrets" {
  description = "Generated GitLab credentials, for the Kubernetes secrets the chart expects to already exist."
  sensitive   = true
  value       = one(module.gitlab[*].helm_secrets)
}
