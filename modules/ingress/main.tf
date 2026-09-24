###############################################################################
# Cluster ingress plumbing: what turns a Kubernetes Service into a real AWS
# load balancer, and a hostname into a Route53 record.
#
#   * AWS Load Balancer Controller -- acts on the aws-load-balancer-* Service
#     annotations. Without it the in-tree cloud provider falls back to a
#     Classic ELB and those annotations are simply never honoured, leaving the
#     Service pending. It matters more than usual under Cilium ENI mode: pods
#     already hold routable VPC IPs, so an ip-target NLB reaches them directly
#     -- no NodePort hop, and the client source IP survives.
#
#   * external-dns -- watches Services, Ingresses and HTTPRoutes and writes
#     the Route53 records itself. That is what avoids a two-stage apply: the
#     load balancer's hostname is only known after it exists, and external-dns
#     fills it in, which is also what lets an HTTP01 ACME challenge succeed.
#
#   * the hosted zone itself, so both controllers and the application module
#     can be given a zone id without any of them owning it.
#
# The zone lives here rather than in the gitlab module on purpose: external-dns
# needs the zone id, and the gitlab release needs external-dns to exist before
# it creates HTTPRoutes. Putting the zone in gitlab would make the two modules
# depend on each other.
###############################################################################

resource "aws_route53_zone" "this" {
  count = var.create_route53_zone ? 1 : 0

  name    = var.domain
  comment = "Managed by Terraform for ${var.cluster_name}"
  tags    = var.tags
}

data "aws_route53_zone" "this" {
  count = var.create_route53_zone ? 0 : 1

  name         = var.domain
  private_zone = false
}

locals {
  zone_id = var.create_route53_zone ? aws_route53_zone.this[0].zone_id : data.aws_route53_zone.this[0].zone_id
}

###############################################################################
# AWS Load Balancer Controller
###############################################################################

data "aws_iam_policy_document" "lbc_assume" {
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
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lbc" {
  name               = "${var.cluster_name}-aws-lbc"
  assume_role_policy = data.aws_iam_policy_document.lbc_assume.json
  tags               = var.tags
}

# Verbatim upstream policy (v3.5.0), kept as a file rather than inlined so it
# can be re-fetched and diffed when the controller is upgraded:
#   curl -o iam-policy-aws-lbc.json \
#     https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v3.5.0/docs/install/iam_policy.json
resource "aws_iam_policy" "lbc" {
  name   = "${var.cluster_name}-aws-lbc"
  policy = file("${path.module}/iam-policy-aws-lbc.json")
  tags   = var.tags
}

resource "aws_iam_role_policy_attachment" "lbc" {
  role       = aws_iam_role.lbc.name
  policy_arn = aws_iam_policy.lbc.arn
}

resource "helm_release" "lbc" {
  name       = "aws-load-balancer-controller"
  namespace  = "kube-system"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = var.lbc_chart_version

  wait    = true
  timeout = 600

  values = [
    yamlencode({
      clusterName = var.cluster_name
      region      = var.aws_region
      vpcId       = var.vpc_id

      serviceAccount = {
        create = true
        name   = "aws-load-balancer-controller"
        annotations = {
          "eks.amazonaws.com/role-arn" = aws_iam_role.lbc.arn
        }
      }

      nodeSelector = var.node_selector
    })
  ]

  depends_on = [aws_iam_role_policy_attachment.lbc]
}

###############################################################################
# external-dns
###############################################################################

data "aws_iam_policy_document" "external_dns_assume" {
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
      values   = ["system:serviceaccount:kube-system:external-dns"]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "external_dns" {
  name               = "${var.cluster_name}-external-dns"
  assume_role_policy = data.aws_iam_policy_document.external_dns_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy" "external_dns" {
  name = "external-dns-route53"
  role = aws_iam_role.external_dns.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["route53:ChangeResourceRecordSets"]
        # Scoped to this one zone rather than all of Route53.
        Resource = ["arn:aws:route53:::hostedzone/${local.zone_id}"]
      },
      {
        Effect   = "Allow"
        Action   = ["route53:ListHostedZones", "route53:ListResourceRecordSets", "route53:ListTagsForResource"]
        Resource = ["*"]
      },
    ]
  })
}

resource "helm_release" "external_dns" {
  name       = "external-dns"
  namespace  = "kube-system"
  repository = "https://kubernetes-sigs.github.io/external-dns/"
  chart      = "external-dns"
  version    = var.external_dns_chart_version

  wait    = true
  timeout = 600

  values = [
    yamlencode({
      provider = { name = "aws" }

      # gateway-httproute is what reads the HTTPRoutes a Gateway API chart
      # creates. Without it external-dns sees no hostnames from them at all.
      sources = ["service", "ingress", "gateway-httproute"]

      policy        = "sync"
      registry      = "txt"
      txtOwnerId    = var.cluster_name
      domainFilters = [var.domain]

      extraArgs = [
        "--aws-zone-type=public",
        "--zone-id-filter=${local.zone_id}",
      ]

      serviceAccount = {
        create = true
        name   = "external-dns"
        annotations = {
          "eks.amazonaws.com/role-arn" = aws_iam_role.external_dns.arn
        }
      }

      nodeSelector = var.node_selector
    })
  ]

  depends_on = [aws_iam_role_policy.external_dns]
}
