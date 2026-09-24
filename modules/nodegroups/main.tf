###############################################################################
# EC2 worker nodes -- EKS managed node groups, all Graviton (arm64).
#
# These are the guaranteed floor for each tier. Karpenter supplies burst
# capacity above them using the same taint and label, so the scheduler treats
# a managed node and a Karpenter node in the same tier as equivalent.
#
# The caller must order this module AFTER the CNI module, even when that
# module installs nothing: no node may be created before something exists to
# make it Ready.
###############################################################################

# One IAM role shared by all node groups, rather than one identical role each.
# Deliberately without AmazonEKS_CNI_Policy: VPC CNI is gone, and under Cilium
# ENI mode only the cilium-operator role may manipulate ENIs.
resource "aws_iam_role" "node" {
  name = "${var.cluster_name}-node"

  # There is no fallback CNI. Module v21 sets bootstrap_self_managed_addons =
  # false and modules/cluster-addons installs no vpc-cni, so with Cilium off a
  # joining node has nothing to make it Ready and every node group would sit
  # until it timed out. Fail at plan time instead of 20 minutes into an apply.
  #
  # This is about *whether* Cilium is the CNI, not who installs it --
  # cilium_install_method = "helm" still satisfies it, because the chart is
  # vendored in helm-charts/ and installed during the NotReady window.
  lifecycle {
    precondition {
      condition     = var.cilium_is_cni
      error_message = "Cilium is the only CNI this configuration installs, so disabling it leaves the cluster with no pod networking. To run a different CNI, add it to modules/cluster-addons and relax this precondition."
    }
  }

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly",
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
  ])

  role       = aws_iam_role.node.name
  policy_arn = each.value
}

module "group" {
  source  = "terraform-aws-modules/eks/aws//modules/eks-managed-node-group"
  version = "~> 21.25"

  for_each = var.node_groups

  name         = "${var.cluster_name}-${each.key}"
  cluster_name = var.cluster_name

  kubernetes_version   = var.kubernetes_version
  cluster_endpoint     = var.cluster_endpoint
  cluster_auth_base64  = var.cluster_auth_base64
  cluster_service_cidr = var.cluster_service_cidr

  subnet_ids             = var.subnet_ids
  vpc_security_group_ids = [var.node_security_group_id]

  ami_type       = each.value.ami_type
  instance_types = each.value.instance_types
  capacity_type  = each.value.capacity_type

  min_size     = each.value.min_size
  max_size     = each.value.max_size
  desired_size = each.value.desired_size

  # disk_size is ignored once the module builds a launch template, which it
  # does by default -- the size has to be set through the block device mapping.
  block_device_mappings = {
    root = {
      device_name = "/dev/xvda"
      ebs = {
        volume_size           = each.value.disk_size
        volume_type           = "gp3"
        encrypted             = true
        delete_on_termination = true
      }
    }
  }

  labels = merge(
    each.value.taint_workload != null ? { workload = each.value.taint_workload } : {},
    each.value.extra_labels,
  )

  taints = each.value.taint_workload != null ? {
    workload = {
      key    = "workload"
      value  = each.value.taint_workload
      effect = "NO_SCHEDULE"
    }
  } : null

  create_iam_role = false
  iam_role_arn    = aws_iam_role.node.arn

  metadata_options = {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  timeouts = {
    create = var.create_timeout
    update = "20m"
    delete = "20m"
  }

  tags = var.tags

  depends_on = [aws_iam_role_policy_attachment.node]
}
