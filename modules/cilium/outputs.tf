output "operator_role_arn" {
  description = "IRSA role the Cilium operator assumes to manage ENIs."
  value       = aws_iam_role.operator.arn
}

output "installed_by_terraform" {
  description = "False under install_method = \"helm\"; the install scripts refuse to run when this is true."
  value       = local.via_terraform
}

output "k8s_service_host" {
  description = "API server host the chart is configured with. Exposed so the Helm-side values can be rendered identically."
  value       = local.k8s_service_host
}
