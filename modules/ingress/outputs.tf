output "route53_zone_id" {
  value = local.zone_id
}

output "route53_zone_nameservers" {
  description = "Delegate the domain to these at your registrar. Until that is done nothing resolves and Let's Encrypt cannot issue a certificate. Empty when the zone was looked up rather than created."
  value       = var.create_route53_zone ? aws_route53_zone.this[0].name_servers : []
}

output "lbc_role_arn" {
  value = aws_iam_role.lbc.arn
}

output "external_dns_role_arn" {
  value = aws_iam_role.external_dns.arn
}

# A value that is only known once both Helm releases have actually been
# installed, for callers that must be ordered after them. The IAM role ARNs
# above are no good for that: they exist well before the controllers run.
output "ready" {
  description = "Opaque token that becomes known only after the LB controller and external-dns releases are installed. Pass to modules that must wait for them."
  value       = join(",", [helm_release.lbc.id, helm_release.external_dns.id])
}
