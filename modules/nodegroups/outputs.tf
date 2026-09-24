output "node_iam_role_name" { value = aws_iam_role.node.name }
output "node_iam_role_arn" { value = aws_iam_role.node.arn }

output "groups" {
  description = "Created node groups, keyed by tier."
  value       = { for k, g in module.group : k => g.node_group_id }
}
