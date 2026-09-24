###############################################################################
# Node IAM role for the attach-to-an-existing-cluster path only.
#
# When Terraform creates the cluster, the Karpenter submodule in
# modules/karpenter creates this role instead, because it also has to register
# it with the new cluster via an EKS access entry. Here there is no new
# cluster to register against, so the role stands alone -- you are expected to
# have granted it access on the existing cluster yourself.
#
# Unlike the create path this DOES attach AmazonEKS_CNI_Policy: an existing
# cluster is assumed to be running the VPC CNI, where every node manages its
# own ENIs.
###############################################################################

data "aws_partition" "current" {}

resource "aws_iam_role" "this" {
  name = var.node_iam_role_name

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.${data.aws_partition.current.dns_suffix}" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "this" {
  for_each = toset([
    "AmazonEKSWorkerNodePolicy",
    "AmazonEKS_CNI_Policy",
    "AmazonEC2ContainerRegistryReadOnly",
    "AmazonSSMManagedInstanceCore",
  ])

  role       = aws_iam_role.this.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/${each.value}"
}

resource "aws_iam_instance_profile" "this" {
  name = "${var.node_iam_role_name}-profile"
  role = aws_iam_role.this.name
  tags = var.tags
}
