output "vpc_id" { value = module.this.vpc_id }
output "private_subnets" { value = module.this.private_subnets }
output "public_subnets" { value = module.this.public_subnets }
output "azs" { value = local.azs }
