###############################################################################
# EKS control plane ONLY.
#
# Node groups deliberately live in modules/nodegroups rather than in this
# module call. With Cilium as the sole CNI there is no VPC CNI to make a
# joining node Ready, so Cilium has to be installed in between the control
# plane and the first node. Terraform cannot order a helm_release between a
# module's cluster and that same module's inline eks_managed_node_groups --
# adding depends_on would create a cycle, since the Helm provider is
# configured from this module's outputs. Splitting compute out makes the
# ordering explicit:
#
#     control plane -> cilium -> node groups -> addons -> karpenter
#
# Note: module v21 hardcodes bootstrap_self_managed_addons = false, so the
# cluster comes up with no aws-node, no kube-proxy and no CoreDNS at all --
# exactly the clean slate a full Cilium replacement wants.
###############################################################################

module "this" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.25"

  name               = var.cluster_name
  kubernetes_version = var.kubernetes_version

  vpc_id     = var.vpc_id
  subnet_ids = var.subnet_ids

  endpoint_public_access       = var.endpoint_public_access
  endpoint_public_access_cidrs = var.endpoint_public_access_cidrs
  endpoint_private_access      = true

  enabled_log_types = var.enabled_log_types

  authentication_mode                      = "API_AND_CONFIG_MAP"
  enable_cluster_creator_admin_permissions = true

  # Required for the Cilium operator's IRSA role. Cilium cannot use EKS Pod
  # Identity: the Pod Identity agent is a DaemonSet that needs a Ready node,
  # and nothing is Ready until Cilium itself is running. IRSA is served by the
  # control plane, so it works during bootstrap.
  enable_irsa = true

  # Addons are created in modules/cluster-addons instead, so they can depend
  # on node groups. Left here, CoreDNS would be created immediately after the
  # control plane, sit DEGRADED with nowhere to schedule, and block the apply
  # until it timed out.
  addons = {}

  node_security_group_tags = {
    # How Karpenter's EC2NodeClass securityGroupSelectorTerms find the node SG.
    "karpenter.sh/discovery" = var.cluster_name
  }

  node_security_group_additional_rules = {
    # The module's recommended rules only open node-to-node TCP 1025-65535.
    # Under Cilium ENI mode every pod holds a real VPC IP, so pod-to-pod traffic
    # is filtered by this security group -- and anything on a well-known port
    # would be dropped, CoreDNS on 53 first among them.
    ingress_self_all = {
      description = "Node/pod to node/pod, all protocols (Cilium ENI mode: pods have VPC IPs)"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      self        = true
    }
  }

  tags = var.tags
}
