output "nodepool_name" {
  value = var.name
}

output "ec2nodeclass_name" {
  value = var.name
}

output "taint" {
  value = "${var.taint_key}=${var.taint_value}:NoSchedule"
}
