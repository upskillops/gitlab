###############################################################################
# Free-plan profile.
#
#   terraform apply -var-file=free-tier.tfvars
#
# This AWS account is on AWS's *Free* account plan, which refuses to launch any
# EC2 instance type that is not Free Tier eligible:
#
#   InvalidParameterCombination - The specified instance type is not eligible
#   for Free Tier.
#
# The entire allowlist is t3.micro, t3.small, t8i.micro, t8i.small,
# c7i-flex.large, m7i-flex.large, t4g.micro and t4g.small -- of which only
# t4g.micro (1 GiB) and t4g.small (2 GiB) are Graviton. Everything here is
# sized to that ceiling.
#
# The restriction is on instance types only: the EKS control plane, NAT
# gateways and other paid resources create normally. Lifting it is a billing
# change (Billing and Cost Management -> Account plan -> upgrade to Paid), not
# a Terraform one; after upgrading, use terraform.tfvars instead and every
# value below reverts to its normal default.
###############################################################################

cluster_name   = "my-eks-cluster"
aws_region     = "us-east-1"
create_cluster = true

# ---------------------------------------------------------------------------
# GitLab is OFF and cannot be turned on under this plan.
#
# GitLab needs ~12-16 GiB across webservice/sidekiq/gitaly/registry/kas. The
# largest node available here is 2 GiB, and RDS/ElastiCache are capped to
# micro classes by the same restriction.
# ---------------------------------------------------------------------------
enable_gitlab = false

# The EBS CSI controller is ~6 containers per replica, which is a real cost on
# 2 GiB nodes. Turn it back on if you need PersistentVolumes.
enable_ebs_csi_driver = false

# ---------------------------------------------------------------------------
# Cost trimming -- one NAT gateway instead of three (~$65/mo saved), and no
# control plane logs to CloudWatch.
# ---------------------------------------------------------------------------
single_nat_gateway        = true
cluster_enabled_log_types = []

# ---------------------------------------------------------------------------
# Control-plane components, scaled to fit.
# ---------------------------------------------------------------------------
# Karpenter's chart has a *required* podAntiAffinity on hostname, so 2 replicas
# would need 2 core nodes purely for itself. One is enough at this size.
karpenter_replicas       = 1
cilium_operator_replicas = 1

# Hubble Relay is an extra pod that buys little on a cluster this small; the
# Cilium agent's local Hubble stays on.
cilium_enable_hubble_relay = false

# ---------------------------------------------------------------------------
# Node groups -- t4g.small (2 vCPU / 2 GiB) Graviton, the largest arm64
# instance the Free plan permits.
#
# app and monitoring are omitted entirely: there is not enough memory to run
# them meaningfully, and an empty tier is clearer than a broken one.
# ---------------------------------------------------------------------------
workload_node_groups = {
  core = {
    instance_types = ["t4g.small"]
    ami_type       = "AL2023_ARM_64_STANDARD"
    capacity_type  = "ON_DEMAND"
    min_size       = 2
    max_size       = 3
    desired_size   = 2
    disk_size      = 20
    taint_workload = null
    extra_labels   = { node-role = "core" }
  }

  infra = {
    instance_types = ["t4g.small"]
    ami_type       = "AL2023_ARM_64_STANDARD"
    capacity_type  = "ON_DEMAND"
    min_size       = 1
    max_size       = 4
    desired_size   = 1
    disk_size      = 20
    taint_workload = "infra"
  }
}

# ---------------------------------------------------------------------------
# Karpenter burst pool.
#
# t4g is instance-generation 4, so the generation floor has to drop from 6 to
# 3 (the comparison is an exclusive Gt). Category "t" plus size "small" plus
# the module's arm64 requirement resolves to exactly t4g.small, which keeps
# Karpenter inside the Free Tier allowlist.
#
# on-demand only: spot eligibility is not guaranteed to follow the free-tier
# allowlist, and a rejected spot launch just loops.
# ---------------------------------------------------------------------------
karpenter_min_instance_generation = "3"

karpenter_nodepools = {
  infra = {
    instance_categories = ["t"]
    instance_sizes      = ["small"]
    capacity_types      = ["on-demand"]
    # Capped at the account's spare vCPU, not at what the tier could use.
    # The quota "Running On-Demand Standard (A,C,D,H,I,M,R,T,Z)" (L-1216C47A)
    # is 8 on this account and t4g counts against it. core(2) + infra(1) at
    # t4g.small already reserves 6, so Karpenter gets the remaining 2 -- one
    # more t4g.small. At cpu = "8" it would try for 14 total and the launches
    # would just fail with VcpuLimitExceeded in a loop.
    limits              = { cpu = "2", memory = "2Gi" }
    consolidate_after   = "5m"
    disruption_budgets  = [{ nodes = "20%" }]
    volume_size_gb      = 20
  }
}

tags = {
  Environment = "free-tier"
  Team        = "platform"
  ManagedBy   = "terraform"
}
