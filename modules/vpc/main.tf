###############################################################################
# VPC. A thin wrapper over terraform-aws-modules/vpc, here only so the root
# stays pure composition -- the two things it adds are AZ selection and the
# subnet tags Kubernetes and Karpenter discover subnets by.
###############################################################################

data "aws_availability_zones" "available" {
  state = "available"

  # Exclude local/wavelength zones, which cannot host EKS nodes.
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)
}

module "this" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.7"

  name = "${var.cluster_name}-vpc"
  cidr = var.cidr

  azs             = local.azs
  public_subnets  = var.public_subnet_cidrs
  private_subnets = var.private_subnet_cidrs

  enable_dns_hostnames = true
  enable_dns_support   = true

  enable_nat_gateway     = true
  single_nat_gateway     = var.single_nat_gateway
  one_nat_gateway_per_az = !var.single_nat_gateway

  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"

    # How Karpenter's EC2NodeClass subnetSelectorTerms find where to launch.
    "karpenter.sh/discovery" = var.cluster_name
  }

  tags = var.tags
}
