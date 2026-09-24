output "node_iam_role_name" {
  description = "IAM role Karpenter attaches to the instances it launches. NodePools reference it by name."
  value       = module.this.node_iam_role_name
}

output "queue_name" { value = module.this.queue_name }

output "release_id" {
  description = "Exposed so NodePools can depend on the controller being up -- a NodePool applied before the CRDs exist fails."
  value       = helm_release.karpenter.id
}
