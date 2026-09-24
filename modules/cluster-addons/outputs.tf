output "storage_class_names" {
  description = "StorageClasses created, so a caller can validate a reference before a PVC hangs Pending."
  value       = keys(kubernetes_storage_class_v1.this)
}

output "default_storage_class" {
  description = "The one class carrying the is-default-class annotation."
  value       = try([for k, v in var.storage_classes : k if v.default][0], null)
}

output "coredns_addon_id" {
  description = "Exposed so callers that need CoreDNS resolving before they start (Karpenter, the LB controller) can depend on it specifically rather than on the whole module."
  value       = aws_eks_addon.coredns.id
}

output "pod_identity_addon_id" {
  value = aws_eks_addon.pod_identity.id
}

# As above: a token that is known only after the pieces GitLab actually needs
# -- the EBS CSI driver and the StorageClasses Gitaly's PVC names -- exist.
output "ready" {
  description = "Opaque token that becomes known only after the addons and StorageClasses are created. Pass to modules that must wait for them."
  value = join(",", concat(
    [for a in aws_eks_addon.ebs_csi : a.id],
    [for s in kubernetes_storage_class_v1.this : s.id],
  ))
}
