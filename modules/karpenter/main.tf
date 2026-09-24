###############################################################################
# Karpenter controller.
#
# Provides burst capacity above the managed node group floors. The v21
# submodule wires the controller up with EKS Pod Identity instead of IRSA,
# which is why the caller must order this module after the Pod Identity agent
# addon in modules/cluster-addons.
###############################################################################

module "this" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 21.25"

  cluster_name = var.cluster_name

  # Node role for Karpenter-launched instances. Kept separate from the managed
  # node group role because the submodule also registers this one with the
  # cluster via its own EKS access entry.
  create_node_iam_role          = true
  node_iam_role_name            = "${var.cluster_name}-karpenter-node"
  node_iam_role_use_name_prefix = false

  # No AmazonEKS_CNI_Policy: Cilium, not VPC CNI, owns ENIs here.
  node_iam_role_attach_cni_policy = false

  node_iam_role_additional_policies = {
    AmazonEC2ContainerRegistryPullOnly = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly"
    AmazonSSMManagedInstanceCore       = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  # Karpenter v1 has the controller manage the instance profile itself through
  # EC2NodeClass.spec.role, so Terraform does not need to create one.
  create_instance_profile = false

  create_access_entry = true
  access_entry_type   = "EC2_LINUX"

  # SQS queue + EventBridge rules for spot interruption and rebalance notices.
  enable_spot_termination = true

  create_pod_identity_association = true

  tags = var.tags
}

resource "helm_release" "karpenter" {
  name             = "karpenter"
  namespace        = "kube-system"
  create_namespace = false

  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = var.chart_version

  wait    = true
  timeout = 600

  values = [
    yamlencode({
      settings = {
        clusterName       = var.cluster_name
        clusterEndpoint   = var.cluster_endpoint
        interruptionQueue = module.this.queue_name
      }

      nodeSelector = var.node_selector
      replicas     = var.replicas
    })
  ]

  depends_on = [module.this]
}
