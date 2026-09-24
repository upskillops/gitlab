provider "aws" {
  region = var.aws_region
}

# Existing-cluster path only: look up a cluster Terraform didn't create.
data "aws_eks_cluster" "existing" {
  count = var.create_cluster ? 0 : 1
  name  = var.cluster_name
}

# Resolved here rather than in main.tf because the provider blocks below are
# what consume them, and they have to work on both paths -- a cluster this
# configuration creates, and one it merely attaches to.
locals {
  cluster_name     = var.create_cluster ? module.eks[0].cluster_name : data.aws_eks_cluster.existing[0].name
  cluster_endpoint = var.create_cluster ? module.eks[0].cluster_endpoint : data.aws_eks_cluster.existing[0].endpoint
  cluster_ca_data  = var.create_cluster ? module.eks[0].cluster_certificate_authority_data : data.aws_eks_cluster.existing[0].certificate_authority[0].data

  node_iam_role_name = var.create_cluster ? module.karpenter[0].node_iam_role_name : module.karpenter_node_iam[0].node_iam_role_name
}

# NOTE ON AUTH -- this is the fix for the single biggest source of failed applies
# in the previous revision. It used `data.aws_eks_cluster_auth`, which mints a
# *static* token that EKS only honours for 15 minutes. The token was resolved
# early in the graph, but the control plane alone takes ~10 minutes to create and
# the node groups a few more, so every Kubernetes/Helm/kubectl resource that ran
# after roughly minute 15 failed with `401 Unauthorized`. Shelling out to
# `aws eks get-token` instead means the token is minted at the moment each
# resource is applied, so apply duration no longer matters.
provider "kubernetes" {
  host                   = local.cluster_endpoint
  cluster_ca_certificate = base64decode(local.cluster_ca_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", local.cluster_name, "--region", var.aws_region]
  }
}

# Unused since Karpenter's manifests moved to kubernetes_manifest on the
# official provider. Kept commented rather than deleted: reverting is a real
# possibility because kubernetes_manifest cannot plan a CRD that does not
# exist yet. See the header of modules/karpenter-nodepool/main.tf.
#
# provider "kubectl" {
#   host                   = local.cluster_endpoint
#   cluster_ca_certificate = base64decode(local.cluster_ca_data)
#   load_config_file       = false
#   apply_retry_count      = 5
#
#   exec {
#     api_version = "client.authentication.k8s.io/v1beta1"
#     command     = "aws"
#     args        = ["eks", "get-token", "--cluster-name", local.cluster_name, "--region", var.aws_region]
#   }
# }

provider "helm" {
  kubernetes {
    host                   = local.cluster_endpoint
    cluster_ca_certificate = base64decode(local.cluster_ca_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", local.cluster_name, "--region", var.aws_region]
    }
  }
}
