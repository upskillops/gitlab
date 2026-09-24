###############################################################################
# Cluster addons and StorageClasses.
#
# The caller must order this module AFTER the node groups. These need somewhere
# to run: created straight after the control plane, CoreDNS would sit DEGRADED
# with nowhere to schedule and stall the apply until it timed out.
#
# There is deliberately no vpc-cni and no kube-proxy addon: Cilium replaces both.
###############################################################################

# Versions are intentionally not pinned. Omitting `addon_version` gives the
# default version AWS ships for this Kubernetes release, which is both
# compatible by construction and one less API lookup per plan.
resource "aws_eks_addon" "coredns" {
  cluster_name = var.cluster_name
  addon_name   = "coredns"

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = var.tags
}

# Required for Karpenter: the v21 Karpenter submodule authenticates its
# controller with EKS Pod Identity rather than IRSA, and Pod Identity needs
# this agent running on the node.
resource "aws_eks_addon" "pod_identity" {
  cluster_name = var.cluster_name
  addon_name   = "eks-pod-identity-agent"

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = var.tags
}

###############################################################################
# EBS CSI driver -- PersistentVolume support.
###############################################################################

resource "aws_iam_role" "ebs_csi" {
  count = var.enable_ebs_csi_driver ? 1 : 0

  name = "${var.cluster_name}-ebs-csi"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  count = var.enable_ebs_csi_driver ? 1 : 0

  role       = aws_iam_role.ebs_csi[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_eks_addon" "ebs_csi" {
  count = var.enable_ebs_csi_driver ? 1 : 0

  cluster_name = var.cluster_name
  addon_name   = "aws-ebs-csi-driver"

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  pod_identity_association {
    role_arn        = aws_iam_role.ebs_csi[0].arn
    service_account = "ebs-csi-controller-sa"
  }

  tags = var.tags

  depends_on = [
    aws_eks_addon.pod_identity,
    aws_iam_role_policy_attachment.ebs_csi,
  ]
}

###############################################################################
# StorageClasses -- one per workload tier.
#
# EKS ships no default StorageClass at all on recent versions, so at minimum
# one has to be declared here or every PVC without an explicit storageClassName
# sits Pending forever.
#
# WHAT A PER-TIER CLASS DOES AND DOES NOT DO
# ------------------------------------------
# A StorageClass is NOT scoped to a node group. It describes how a volume is
# provisioned -- type, IOPS, throughput, encryption, reclaim policy -- not
# where the pod runs, and nothing stops an app pod from naming gp3-monitoring.
# What makes storage actually follow a tier is the combination of:
#
#   * volumeBindingMode = WaitForFirstConsumer (set on every class below). The
#     volume is not created until a pod is scheduled, so it is provisioned in
#     the AZ of whichever node won -- and pods are already pinned to their tier
#     by nodeSelector + taints. Without this an EBS volume could be created in
#     an AZ where that tier has no capacity, and the pod would never schedule.
#   * the pod naming its tier's class in the PVC.
#
# To *enforce* that a namespace may only use its own tier's class, add a
# ResourceQuota with <class>.storageclass.storage.k8s.io/requests.storage = 0
# for every other class. Not done here because the tiers are taints rather
# than namespaces today.
#
# Not created via the aws-ebs-csi-driver addon's own defaultStorageClass
# option: that one is hardcoded to the name "ebs-csi-default-sc" and emits no
# parameters block at all, so it cannot set encrypted, type, iops or
# throughput. On an account without EBS encryption-by-default that silently
# gives you plaintext volumes.
###############################################################################

resource "kubernetes_storage_class_v1" "this" {
  for_each = var.enable_ebs_csi_driver ? var.storage_classes : {}

  metadata {
    name = each.key

    # Kubernetes picks arbitrarily if two classes claim to be default, so the
    # annotation is only emitted for the one that does.
    annotations = each.value.default ? {
      "storageclass.kubernetes.io/is-default-class" = "true"
    } : {}

    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "workload-tier"                = coalesce(each.value.tier, "shared")
    }
  }

  storage_provisioner = "ebs.csi.aws.com"

  # Retain keeps the EBS volume after its PVC is deleted. Correct for data
  # that cannot be regenerated (Gitaly holds your git repositories); wrong for
  # data that can, because the orphaned volumes keep costing money.
  reclaim_policy = each.value.reclaim_policy

  # See the comment block above -- this is what ties a volume to the AZ the
  # tier actually scheduled in.
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = each.value.allow_volume_expansion

  parameters = merge(
    {
      type = each.value.type
      # Not inherited from anywhere: with EBS encryption-by-default off on the
      # account, omitting this means plaintext volumes.
      encrypted = tostring(each.value.encrypted)
    },
    # gp3 bills baseline 3000 IOPS / 125 MiB/s for free and charges above it,
    # so these are only set where a tier actually needs the headroom.
    each.value.iops != null ? { iops = tostring(each.value.iops) } : {},
    each.value.throughput != null ? { throughput = tostring(each.value.throughput) } : {},
    # Null means the AWS-managed aws/ebs key. Set a CMK per tier if you need
    # the tiers cryptographically separated.
    each.value.kms_key_id != null ? { kmsKeyId = each.value.kms_key_id } : {},
  )

  depends_on = [aws_eks_addon.ebs_csi]
}
