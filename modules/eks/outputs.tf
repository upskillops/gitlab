output "cluster_name" { value = module.this.cluster_name }
output "cluster_endpoint" { value = module.this.cluster_endpoint }
output "cluster_version" { value = module.this.cluster_version }
output "cluster_service_cidr" { value = module.this.cluster_service_cidr }
output "node_security_group_id" { value = module.this.node_security_group_id }

output "cluster_certificate_authority_data" {
  value = module.this.cluster_certificate_authority_data
}

output "oidc_provider_arn" { value = module.this.oidc_provider_arn }

output "oidc_provider" {
  description = "OIDC issuer host without the scheme, for IRSA trust conditions."
  value       = module.this.oidc_provider
}
