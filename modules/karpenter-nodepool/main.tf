###############################################################################
# Karpenter EC2NodeClass + NodePool.
#
# Submitted through a tiny carrier chart in ./chart rather than with
# kubernetes_manifest, and that choice is the whole reason a fresh cluster can
# be built with ONE `terraform apply`.
#
# kubernetes_manifest resolves a resource's GroupVersionResource against the
# live API server at PLAN time. Karpenter's NodePool/EC2NodeClass CRDs are
# installed by the Karpenter Helm release in the same apply, so plan failed
# before anything existed:
#
#   no cluster yet        Error: Failed to construct REST client
#   cluster, but no CRDs  no matches for karpenter.sh/v1, Resource=nodepool
#
# depends_on could not help -- it orders apply, not plan -- so the old way out
# was a two-stage `terraform apply -target=module.karpenter` followed by a full
# apply. helm_release does no plan-time schema lookup, so depends_on is now
# sufficient and the targeted first stage is gone.
#
# The trade is that Helm tracks these as release contents rather than as typed
# Terraform resources: `terraform plan` shows a values diff, not a field-level
# diff. In exchange the server is free to default and normalise fields without
# provoking "provider produced inconsistent result", which is what the old
# computed_fields list existed to suppress.
###############################################################################

locals {
  subnet_selector_terms = length(var.subnet_selector_terms) > 0 ? var.subnet_selector_terms : [
    { tags = { "karpenter.sh/discovery" = var.cluster_name } }
  ]

  security_group_selector_terms = length(var.security_group_selector_terms) > 0 ? var.security_group_selector_terms : [
    { tags = { "karpenter.sh/discovery" = var.cluster_name } }
  ]

  node_labels = merge(
    { (var.taint_key) = var.taint_value },
    var.extra_labels,
  )

  ec2nodeclass = {
    apiVersion = "karpenter.k8s.aws/v1"
    kind       = "EC2NodeClass"
    metadata = {
      name = var.name
    }
    spec = {
      # amiSelectorTerms is REQUIRED by the Karpenter v1 CRD. A revision that
      # set only `amiFamily` and omitted this had every EC2NodeClass rejected
      # by the API server, so no Karpenter node could ever launch. The alias
      # form ("al2023@latest") also implies the family.
      amiSelectorTerms = [{ alias = var.ami_alias }]

      role                       = var.node_iam_role_name
      subnetSelectorTerms        = local.subnet_selector_terms
      securityGroupSelectorTerms = local.security_group_selector_terms

      blockDeviceMappings = [{
        deviceName = "/dev/xvda"
        ebs = {
          volumeSize          = "${var.volume_size_gb}Gi"
          volumeType          = "gp3"
          encrypted           = true
          deleteOnTermination = true
        }
      }]

      metadataOptions = {
        httpEndpoint            = "enabled"
        httpProtocolIPv6        = "disabled"
        httpPutResponseHopLimit = 2
        httpTokens              = "required"
      }

      tags = merge(var.tags, {
        "karpenter.sh/discovery" = var.cluster_name
        "nodepool"               = var.name
      })
    }
  }

  nodepool = {
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata = {
      name = var.name
    }
    spec = {
      template = {
        metadata = {
          labels = local.node_labels
        }
        spec = {
          nodeClassRef = {
            group = "karpenter.k8s.aws"
            kind  = "EC2NodeClass"
            name  = var.name
          }

          # Same taint the tier's managed node group applies, so the scheduler
          # sees managed nodes and Karpenter nodes in this tier as equivalent.
          taints = [{
            key    = var.taint_key
            value  = var.taint_value
            effect = "NoSchedule"
          }]

          requirements = concat(
            [
              # Graviton only. Combined with the generation floor below this
              # resolves to the 7g/8g families (c7g/c8g, m7g/m8g, r7g/r8g).
              { key = "kubernetes.io/arch", operator = "In", values = [var.architecture] },
              { key = "karpenter.k8s.aws/instance-category", operator = "In", values = var.instance_categories },
              { key = "karpenter.k8s.aws/instance-size", operator = "In", values = var.instance_sizes },
              { key = "karpenter.sh/capacity-type", operator = "In", values = var.capacity_types },
              { key = "kubernetes.io/os", operator = "In", values = ["linux"] },
            ],
            var.min_instance_generation != null ? [
              { key = "karpenter.k8s.aws/instance-generation", operator = "Gt", values = [var.min_instance_generation] }
            ] : []
          )

          expireAfter = var.expire_after
        }
      }

      limits = var.limits

      disruption = {
        consolidationPolicy = var.consolidation_policy
        consolidateAfter    = var.consolidate_after
        budgets             = var.disruption_budgets
      }
    }
  }
}

resource "helm_release" "nodepool" {
  name      = var.name
  namespace = var.namespace
  chart     = "${path.module}/chart"

  # Ordering within the release: Helm applies the EC2NodeClass and the NodePool
  # together. The NodePool references the EC2NodeClass by name, and Karpenter
  # tolerates that reference being briefly unresolved -- the NodePool simply
  # reports NotReady until the class registers, then reconciles. No hook
  # weighting needed.
  values = [yamlencode({
    manifests = [
      local.ec2nodeclass,
      local.nodepool,
    ]
  })]

  # Nothing here owns a pod, so there is no rollout to wait for. Waiting would
  # only add dead time to the apply.
  wait          = false
  wait_for_jobs = false
  atomic        = false

  # Karpenter's CRDs must be registered before these objects are applied. That
  # is an APPLY-time requirement, which depends_on in the caller satisfies --
  # unlike the plan-time requirement kubernetes_manifest imposed.
  timeout = 300

  # A CRD upgrade can change how the server normalises these objects; recreate
  # rather than fail the apply on an unpatchable field.
  recreate_pods = false
  force_update  = true
}
