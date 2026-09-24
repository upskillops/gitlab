###############################################################################
# Cilium -- sole CNI, full VPC CNI + kube-proxy replacement.
#
# This module is instantiated only when Cilium is the cluster's CNI, so there
# are no `count = enabled ? 1 : 0` guards inside it -- the caller decides.
#
# WHO RUNS THE CHART is var.install_method. The IAM below is created either
# way; only the helm_release at the bottom is conditional.
#
#   "helm" (default) -- Terraform stops at the IRSA role. The apply creates a
#   cluster with no CNI, then node groups whose nodes join and stay NotReady;
#   the operator installs the vendored chart with
#   helm-charts/bin/install-cilium.sh and the nodes flip to Ready. Cilium is a
#   normal Helm release from then on. The apply BLOCKS in the NotReady window.
#
#   "terraform" -- the original single-apply order, which is subtle:
#     1. Control plane is created with no CNI and no kube-proxy at all.
#     2. Cilium is installed here with wait = false. There are no nodes yet, so
#        every Cilium pod is Pending -- waiting would deadlock the apply.
#     3. Node groups are created. Nodes join NotReady.
#     4. cilium-agent is a DaemonSet and tolerates NotReady nodes; it runs on
#        the host network, writes /etc/cni/net.d, and the node flips to Ready.
#     5. The managed node group's own "wait for ACTIVE" is what makes step 4
#        block the apply until networking genuinely works.
#
# Either way the classic deadlock is cilium-operator: in ENI mode the agent
# cannot assign pod IPs until the operator has attached an ENI, but a normal
# Deployment needs a pod IP to start. The chart avoids this by defaulting
# operator.hostNetwork = true, so the operator runs on the node's own IP.
###############################################################################

locals {
  via_terraform = var.install_method == "terraform"

  # Scheme stripped: the chart wants a bare host.
  k8s_service_host = replace(var.cluster_endpoint, "https://", "")
}

data "aws_iam_policy_document" "operator_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider}:sub"
      values   = ["system:serviceaccount:kube-system:cilium-operator"]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "operator" {
  name               = "${var.cluster_name}-cilium-operator"
  assume_role_policy = data.aws_iam_policy_document.operator_assume.json
  tags               = var.tags
}

# ENI IPAM: the operator creates/attaches ENIs and hands addresses to agents.
# Note the node role deliberately does NOT get AmazonEKS_CNI_Policy -- with VPC
# CNI gone, ENI management is this role's job alone, not every node's.
resource "aws_iam_role_policy" "operator" {
  name = "cilium-operator-eni"
  role = aws_iam_role.operator.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeNetworkInterfaces",
          "ec2:DescribeSubnets",
          "ec2:DescribeVpcs",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeTags",
          "ec2:DescribeRouteTables",
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:CreateNetworkInterface",
          "ec2:AttachNetworkInterface",
          "ec2:DeleteNetworkInterface",
          "ec2:DetachNetworkInterface",
          "ec2:ModifyNetworkInterfaceAttribute",
          "ec2:AssignPrivateIpAddresses",
          "ec2:UnassignPrivateIpAddresses",
          "ec2:CreateTags",
        ]
        Resource = "*"
      },
    ]
  })
}

# Only rendered when install_method = "terraform". Under the default "helm" the
# equivalent values live in helm-charts/values/cilium.values.yaml -- keep the
# two in step if you change one.
resource "helm_release" "cilium" {
  count = local.via_terraform ? 1 : 0

  name       = "cilium"
  namespace  = "kube-system"
  repository = "https://helm.cilium.io/"
  chart      = "cilium"
  version    = var.chart_version

  # Must not wait: at this point the cluster has zero nodes, so nothing can
  # become Ready. Node group creation downstream is what proves Cilium works.
  wait    = false
  atomic  = false
  timeout = 600

  values = [
    yamlencode({
      # --- IPAM: real VPC IPs per pod, no overlay -------------------------
      eni = {
        enabled                   = true
        awsEnablePrefixDelegation = var.enable_prefix_delegation
        awsReleaseExcessIPs       = true
        # Don't look for the legacy cilium-aws secret; we use IRSA.
        iamRole = aws_iam_role.operator.arn
      }
      ipam = {
        mode = "eni"
      }
      routingMode                = "native"
      ipv4NativeRoutingCIDR      = var.vpc_cidr
      endpointRoutes             = { enabled = true }
      egressMasqueradeInterfaces = "eth0"

      # --- kube-proxy replacement -----------------------------------------
      kubeProxyReplacement = "true"
      k8sServiceHost       = local.k8s_service_host
      k8sServicePort       = 443

      cni = {
        # Remove any other CNI conf file rather than chaining with it.
        exclusive = true
      }

      serviceAccounts = {
        operator = {
          name = "cilium-operator"
          annotations = {
            "eks.amazonaws.com/role-arn" = aws_iam_role.operator.arn
          }
        }
      }

      operator = {
        replicas = var.operator_replicas
        # Explicit even though it is the chart default -- ENI mode deadlocks
        # without it, so it should be visible rather than inherited.
        hostNetwork = true
      }

      hubble = {
        enabled = true
        relay   = { enabled = var.enable_hubble_relay }
        ui      = { enabled = false }
      }

      # No arch nodeSelector on purpose: the Cilium images are multi-arch, and
      # pinning the agent DaemonSet to arm64 would silently leave any future
      # amd64 node with no CNI at all.
    })
  ]

  depends_on = [aws_iam_role_policy.operator]
}
