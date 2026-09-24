###############################################################################
# Composition.
#
# This file wires modules together and declares nothing else. Every resource
# lives in modules/; the root holds only main.tf, variables.tf, outputs.tf,
# providers.tf, versions.tf and the tfvars.
#
# Ordering between the modules is the whole point of the design, so it is
# stated explicitly with depends_on rather than left to be inferred:
#
#   vpc -> eks -> [cilium] -> nodegroups -> cluster-addons -> ingress -> gitlab
#                                                   \-> karpenter -> nodepools
#
# The brackets around cilium are deliberate: under the default
# cilium_install_method = "helm" that module creates only an IAM role, and the
# CNI arrives out of band while nodegroups blocks. See ../helm-charts.
###############################################################################

locals {
  # Cilium is this cluster's CNI: governs the operator IRSA role, and the
  # absence of the vpc-cni / kube-proxy addons in modules/cluster-addons.
  install_cilium = var.create_cluster && var.install_cilium

  # ...and this decides whether Terraform is also the thing that installs it,
  # which is what sets the node group create timeout below.
  cilium_via_terraform = local.install_cilium && var.cilium_install_method == "terraform"

  # 20m when Terraform installs Cilium: a node that is not Ready by then is a
  # genuine failure and should surface fast. 45m when Helm does, because the
  # apply has to sit in the NotReady window long enough for the operator to
  # run install-cilium.sh.
  node_group_create_timeout = coalesce(
    var.node_group_create_timeout,
    local.cilium_via_terraform ? "20m" : "45m",
  )

  # Governs the AWS side of GitLab: RDS, ElastiCache, S3, Route53, IRSA. True
  # regardless of who installs the chart -- the datastores have to exist
  # before either Terraform or `helm install` can point the chart at them.
  gitlab_enabled = var.create_cluster && var.enable_gitlab
}

###############################################################################
# Network and control plane
###############################################################################

module "vpc" {
  count  = var.create_cluster ? 1 : 0
  source = "./modules/vpc"

  cluster_name         = var.cluster_name
  cidr                 = var.vpc_cidr
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  az_count             = var.az_count
  single_nat_gateway   = var.single_nat_gateway

  tags = var.tags
}

module "eks" {
  count  = var.create_cluster ? 1 : 0
  source = "./modules/eks"

  cluster_name       = var.cluster_name
  kubernetes_version = var.kubernetes_version

  vpc_id     = module.vpc[0].vpc_id
  subnet_ids = module.vpc[0].private_subnets

  endpoint_public_access       = var.cluster_endpoint_public_access
  endpoint_public_access_cidrs = var.cluster_endpoint_public_access_cidrs
  enabled_log_types            = var.cluster_enabled_log_types

  tags = var.tags
}

###############################################################################
# CNI -- must exist before any node is created, even when it installs nothing
###############################################################################

module "cilium" {
  count  = local.install_cilium ? 1 : 0
  source = "./modules/cilium"

  cluster_name      = module.eks[0].cluster_name
  cluster_endpoint  = module.eks[0].cluster_endpoint
  oidc_provider_arn = module.eks[0].oidc_provider_arn
  oidc_provider     = module.eks[0].oidc_provider
  vpc_cidr          = var.vpc_cidr

  chart_version            = var.cilium_version
  install_method           = var.cilium_install_method
  enable_prefix_delegation = var.cilium_enable_prefix_delegation
  enable_hubble_relay      = var.cilium_enable_hubble_relay
  operator_replicas        = var.cilium_operator_replicas

  tags = var.tags
}

###############################################################################
# Compute
###############################################################################

module "nodegroups" {
  count  = var.create_cluster ? 1 : 0
  source = "./modules/nodegroups"

  cluster_name         = module.eks[0].cluster_name
  kubernetes_version   = module.eks[0].cluster_version
  cluster_endpoint     = module.eks[0].cluster_endpoint
  cluster_auth_base64  = module.eks[0].cluster_certificate_authority_data
  cluster_service_cidr = module.eks[0].cluster_service_cidr

  subnet_ids             = module.vpc[0].private_subnets
  node_security_group_id = module.eks[0].node_security_group_id

  node_groups    = var.workload_node_groups
  cilium_is_cni  = var.install_cilium
  create_timeout = local.node_group_create_timeout

  tags = var.tags

  # The ordering the whole Cilium design turns on. Under
  # cilium_install_method = "helm" the module's release has count 0, so this
  # edge only carries the IAM role -- nodes are created with no CNI on
  # purpose, join NotReady, and wait for install-cilium.sh. This module is
  # then the thing that proves the install worked: it cannot reach ACTIVE
  # until a node is Ready.
  depends_on = [module.cilium]
}

###############################################################################
# Addons and storage
#
# After the node groups, not before: CoreDNS and the EBS CSI controller need
# somewhere to run, and created earlier they would sit DEGRADED and stall the
# apply until it timed out.
###############################################################################

module "cluster_addons" {
  count  = var.create_cluster ? 1 : 0
  source = "./modules/cluster-addons"

  cluster_name          = module.eks[0].cluster_name
  enable_ebs_csi_driver = var.enable_ebs_csi_driver
  storage_classes       = var.storage_classes

  tags = var.tags

  depends_on = [module.nodegroups]
}

###############################################################################
# Karpenter -- burst above the node group floors
###############################################################################

module "karpenter" {
  count  = var.create_cluster ? 1 : 0
  source = "./modules/karpenter"

  cluster_name     = module.eks[0].cluster_name
  cluster_endpoint = module.eks[0].cluster_endpoint
  chart_version    = var.karpenter_version
  replicas         = var.karpenter_replicas

  tags = var.tags

  # cluster_addons carries both the CoreDNS addon (the controller needs DNS)
  # and the Pod Identity agent, which is how the v21 submodule authenticates
  # the controller -- without it Karpenter cannot call EC2 at all.
  depends_on = [module.cluster_addons]
}

# Attach-to-an-existing-cluster path only. On the create path the node role is
# created and named by the Karpenter submodule above.
module "karpenter_node_iam" {
  count  = var.create_cluster ? 0 : 1
  source = "./modules/karpenter-node-iam"

  node_iam_role_name = var.node_iam_role_name
  tags               = var.tags
}

# Each pool shares its tier's taint (workload=<tier>:NoSchedule) and label with
# the managed node group of the same name, so a tier's pods schedule onto
# either half without knowing which is which.
module "nodepool" {
  source = "./modules/karpenter-nodepool"

  for_each = var.karpenter_nodepools

  name               = "${each.key}-pool"
  cluster_name       = local.cluster_name
  node_iam_role_name = local.node_iam_role_name

  taint_value = each.key

  architecture            = "arm64" # Graviton
  ami_alias               = var.karpenter_ami_alias
  min_instance_generation = var.karpenter_min_instance_generation

  instance_categories = each.value.instance_categories
  instance_sizes      = each.value.instance_sizes
  capacity_types      = each.value.capacity_types

  volume_size_gb = each.value.volume_size_gb
  limits         = each.value.limits

  consolidate_after  = each.value.consolidate_after
  disruption_budgets = each.value.disruption_budgets

  tags = var.tags

  depends_on = [module.karpenter]
}

###############################################################################
# Ingress: load balancer controller, external-dns, and the hosted zone.
#
# Follows the GitLab switch because nothing else here currently needs an
# AWS-provisioned load balancer, but it is not GitLab-specific.
###############################################################################

module "ingress" {
  count  = local.gitlab_enabled ? 1 : 0
  source = "./modules/ingress"

  cluster_name      = module.eks[0].cluster_name
  aws_region        = var.aws_region
  vpc_id            = module.vpc[0].vpc_id
  oidc_provider_arn = module.eks[0].oidc_provider_arn
  oidc_provider     = module.eks[0].oidc_provider

  domain              = var.gitlab_domain
  create_route53_zone = var.create_route53_zone

  tags = var.tags

  depends_on = [module.cluster_addons]
}

###############################################################################
# GitLab
###############################################################################

# Preconditions about the *caller's* configuration rather than the module's
# own inputs, so they cannot live as variable validations inside it. All three
# are failure modes that otherwise surface twenty minutes into an install as a
# Pending pod.
resource "terraform_data" "gitlab_preconditions" {
  count = local.gitlab_enabled ? 1 : 0

  lifecycle {
    precondition {
      condition     = var.enable_ebs_csi_driver
      error_message = "enable_ebs_csi_driver must be true when enable_gitlab = true: Gitaly stores git repositories on a PersistentVolume, which needs the EBS CSI driver and a StorageClass."
    }

    precondition {
      condition     = contains(keys(var.storage_classes), var.gitlab_storage_class)
      error_message = "gitlab_storage_class (\"${var.gitlab_storage_class}\") is not a key in storage_classes. Available: ${join(", ", keys(var.storage_classes))}."
    }

    precondition {
      condition     = try(var.workload_node_groups["infra"].min_size, 0) >= 1
      error_message = "workload_node_groups[\"infra\"].min_size must be at least 1 when enable_gitlab = true. GitLab is pinned to the managed infra nodes (it is stateful and must not run on the Karpenter spot pool), so a floor of 0 would leave every GitLab pod Pending."
    }
  }
}

module "gitlab" {
  count  = local.gitlab_enabled ? 1 : 0
  source = "./modules/gitlab"

  cluster_name           = module.eks[0].cluster_name
  aws_region             = var.aws_region
  vpc_id                 = module.vpc[0].vpc_id
  private_subnet_ids     = module.vpc[0].private_subnets
  node_security_group_id = module.eks[0].node_security_group_id
  oidc_provider_arn      = module.eks[0].oidc_provider_arn
  oidc_provider          = module.eks[0].oidc_provider

  namespace      = var.gitlab_namespace
  domain         = var.gitlab_domain
  acme_email     = var.gitlab_acme_email
  install_method = var.gitlab_install_method

  chart_version        = var.gitlab_chart_version
  wait_for_rollout     = var.gitlab_wait_for_rollout
  infra_nodegroup_name = "${var.cluster_name}-infra"

  db_instance_class      = var.gitlab_db_instance_class
  db_engine_version      = var.gitlab_db_engine_version
  db_allocated_storage   = var.gitlab_db_allocated_storage
  db_multi_az            = var.gitlab_db_multi_az
  db_deletion_protection = var.gitlab_db_deletion_protection

  redis_node_type      = var.gitlab_redis_node_type
  redis_engine_version = var.gitlab_redis_engine_version

  webservice_replicas  = var.gitlab_webservice_replicas
  sidekiq_replicas     = var.gitlab_sidekiq_replicas
  gitaly_storage_size  = var.gitlab_gitaly_storage_size
  gitaly_storage_class = var.gitlab_storage_class
  runner_helper_image  = var.gitlab_runner_helper_image

  tags = var.tags

  # The release needs the gp3 StorageClass to exist (Gitaly's PVC), and needs
  # the LB controller and external-dns running before it creates a Gateway --
  # otherwise the Service sits pending and no DNS record is ever written.
  #
  # Passed as a VALUE, not as `depends_on` on this module block. A module-level
  # depends_on applies to every resource in the module, which put the RDS
  # instance and the ElastiCache group -- neither of which touches Kubernetes --
  # behind the entire cluster build. Roughly 15 minutes of database creation
  # that AWS was happy to do in parallel with the control plane was instead
  # tacked onto the end of the apply. Only the Kubernetes resources gate on
  # this now; see terraform_data.k8s_gate in modules/gitlab/release.tf.
  k8s_dependencies = local.gitlab_enabled ? [
    one(module.cluster_addons[*].ready),
    one(module.ingress[*].ready),
  ] : []

  # Static validation only -- instantaneous, so it costs nothing to gate the
  # whole module on it.
  depends_on = [terraform_data.gitlab_preconditions]
}
