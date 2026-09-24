###############################################################################
# Option A: Terraform creates VPC + EKS + Cilium + Graviton node groups + Karpenter
###############################################################################

cluster_name   = "my-eks-cluster"
aws_region     = "us-east-1"
create_cluster = true

# kubernetes_version = "1.35"
# vpc_cidr           = "10.0.0.0/16"
#
# public_subnet_cidrs  = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
# private_subnet_cidrs = ["10.0.16.0/20", "10.0.32.0/20", "10.0.48.0/20"]
#
# single_nat_gateway = false   # true = one shared NAT (cheaper, not HA)
#
# cluster_endpoint_public_access       = true
# cluster_endpoint_public_access_cidrs = ["0.0.0.0/0"]

###############################################################################
# Who installs the charts
#
# Both default to "helm": Terraform builds the AWS side, and Cilium and GitLab
# are installed from the vendored charts in ../helm-charts with plain helm
# commands, so `helm diff` / `history` / `rollback` work on them.
#
# Consequence for Cilium: no CNI is installed during the apply, so nodes join
# NotReady and the apply BLOCKS until Cilium is installed out of band. Run
# ../helm-charts/bin/bootstrap.sh, which does the apply and the Cilium install
# together, or keep a second terminal ready for
# ../helm-charts/bin/install-cilium.sh.
#
# Set either to "terraform" to go back to a single self-contained apply.
###############################################################################

# cilium_install_method = "helm"
# gitlab_install_method = "helm"

# Node group create timeout. Defaults to 20m with cilium_install_method =
# "terraform" and 45m with "helm" -- the apply has to sit through the NotReady
# window. Raise it if you are installing Cilium by hand and want more slack.
# node_group_create_timeout = "45m"

###############################################################################
# Cilium (sole CNI: replaces both VPC CNI and kube-proxy)
###############################################################################

# install_cilium                  = true
# cilium_version                  = "1.19.8"
# cilium_enable_prefix_delegation = true
# cilium_enable_hubble_relay      = true

###############################################################################
# Graviton worker node groups -- the guaranteed floor per tier.
# Uncomment and edit to override. Defaults are in variables.tf.
###############################################################################

# workload_node_groups = {
#   core = {
#     instance_types = ["m7g.large", "m8g.large"]
#     min_size       = 2
#     max_size       = 4
#     desired_size   = 2
#     disk_size      = 50
#     taint_workload = null                      # untainted: hosts CoreDNS / Cilium / Karpenter
#     extra_labels   = { node-role = "core" }
#   }
#   infra = {
#     instance_types = ["c7g.large", "c8g.large", "m7g.large"]
#     min_size       = 0                         # infra bursts on Karpenter alone
#     max_size       = 10
#     desired_size   = 0
#     disk_size      = 50
#     taint_workload = "infra"
#   }
#   app = {
#     instance_types = ["m7g.xlarge", "m8g.xlarge", "r7g.xlarge"]
#     min_size       = 3
#     max_size       = 30
#     desired_size   = 3
#     disk_size      = 80
#     taint_workload = "app"
#   }
#   monitoring = {
#     instance_types = ["r7g.xlarge", "r8g.xlarge", "m7g.2xlarge"]
#     min_size       = 2
#     max_size       = 8
#     desired_size   = 2
#     disk_size      = 150
#     taint_workload = "monitoring"
#   }
# }

###############################################################################
# Karpenter burst pools -- keys must match workload_node_groups keys
###############################################################################

# karpenter_version                 = "1.14.1"
# karpenter_min_instance_generation = "6"       # 7g/8g Graviton only
# karpenter_ami_alias               = "al2023@latest"

###############################################################################
# Addons
###############################################################################

# enable_ebs_csi_driver = true   # needed for Prometheus/Loki PersistentVolumes

###############################################################################
# GitLab
#
# gitlab_domain and gitlab_acme_email are REQUIRED while enable_gitlab = true.
# Terraform fails at plan time if either is missing, rather than 20 minutes
# into an install.
#
# After the first apply, delegate the domain to the nameservers printed by
#   terraform output gitlab_nameservers
# at your registrar. Until that delegation exists the UI will not resolve and
# Let's Encrypt cannot issue the certificate.
###############################################################################

enable_gitlab     = true
gitlab_domain     = "REPLACE-ME.example.com"
gitlab_acme_email = "REPLACE-ME@example.com"

# create_route53_zone = true    # false if the hosted zone already exists
# gitlab_namespace    = "gitlab"

# ---- Datastores (chart v10 requires all three to be external) ----
# gitlab_db_instance_class      = "db.m7g.large"   # Graviton
# gitlab_db_engine_version      = "17.11"          # chart v10 requires PG >= 17
# gitlab_db_allocated_storage   = 100
# gitlab_db_multi_az            = false
# gitlab_db_deletion_protection = false
# gitlab_redis_node_type        = "cache.m7g.large"

# ---- Sizing ----
# gitlab_webservice_replicas = 2
# gitlab_sidekiq_replicas    = 2
# gitlab_gitaly_storage_size = "100Gi"

# Block apply until every GitLab pod is Ready (adds 10-20 min to a first install)
# gitlab_wait_for_rollout = false

###############################################################################
# Option B: attach NodePools to a cluster you already have
###############################################################################

# cluster_name       = "my-existing-eks-cluster"
# create_cluster     = false
# node_iam_role_name = "karpenter-node-role"

###############################################################################
# Common
###############################################################################

tags = {
  Environment = "prod"
  Team        = "platform"
  ManagedBy   = "terraform"
}
