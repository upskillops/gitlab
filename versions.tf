terraform {
  required_version = ">= 1.7.0"

  required_providers {
    # terraform-aws-modules/eks v21 requires aws >= 6.59
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.59"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.38"
    }
    # Karpenter's NodePool/EC2NodeClass now go through kubernetes_manifest on
    # the official provider above. Kept commented rather than deleted -- see
    # the header of modules/karpenter-nodepool/main.tf for the plan-time CRD
    # caveat that makes reverting a real possibility.
    #
    # kubectl = {
    #   source  = "gavinbunney/kubectl"
    #   version = "~> 1.19"
    # }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    tls = {
      source  = "hashicorp/tls"
      version = ">= 4.0"
    }
    time = {
      source  = "hashicorp/time"
      version = ">= 0.9"
    }
  }
}
