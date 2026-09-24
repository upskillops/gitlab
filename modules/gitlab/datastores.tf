###############################################################################
# GitLab datastores -- RDS PostgreSQL + ElastiCache Redis, both Graviton.
#
# These are not optional extras. GitLab Helm chart v10.0.0 REMOVED the bundled
# PostgreSQL, Redis and object storage subcharts; the chart now refuses to
# render without external ones.
###############################################################################

locals {
  db_name     = "gitlabhq_production"
  db_username = "gitlab"

  # Pin GitLab to the *managed* infra nodes rather than the whole infra tier.
  # EKS labels every managed node group node with this automatically. Using it
  # instead of `workload: infra` keeps GitLab off the Karpenter infra pool,
  # which includes spot -- Gitaly owns an EBS volume holding your git
  # repositories and must not be interrupted. CI job pods are the opposite
  # case and are deliberately allowed onto spot (see the runner config).
  nodegroup_name = coalesce(var.infra_nodegroup_name, "${var.cluster_name}-infra")

  node_selector = {
    "eks.amazonaws.com/nodegroup" = local.nodegroup_name
  }

  tolerations = [{
    key      = "workload"
    operator = "Equal"
    value    = "infra"
    effect   = "NoSchedule"
  }]

  via_terraform = var.install_method == "terraform"
}

# ---------------------------------------------------------------------------
# Credentials
# ---------------------------------------------------------------------------

resource "random_password" "db" {
  length = 32
  # RDS rejects '/', '@', '"' and space in a master password.
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "random_password" "redis" {
  length  = 64
  special = false # ElastiCache auth tokens allow only alphanumerics and a few symbols
}

# ---------------------------------------------------------------------------
# Networking
# ---------------------------------------------------------------------------

resource "aws_db_subnet_group" "this" {
  name       = "${var.cluster_name}-gitlab"
  subnet_ids = var.private_subnet_ids
  tags       = var.tags
}

resource "aws_security_group" "db" {
  name        = "${var.cluster_name}-gitlab-db"
  description = "GitLab PostgreSQL -- reachable only from cluster nodes"
  vpc_id      = var.vpc_id
  tags        = var.tags
}

resource "aws_vpc_security_group_ingress_rule" "db" {
  security_group_id            = aws_security_group.db.id
  referenced_security_group_id = var.node_security_group_id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  description                  = "PostgreSQL from EKS nodes"
}

resource "aws_elasticache_subnet_group" "this" {
  name       = "${var.cluster_name}-gitlab"
  subnet_ids = var.private_subnet_ids
  tags       = var.tags
}

resource "aws_security_group" "redis" {
  name        = "${var.cluster_name}-gitlab-redis"
  description = "GitLab Redis -- reachable only from cluster nodes"
  vpc_id      = var.vpc_id
  tags        = var.tags
}

resource "aws_vpc_security_group_ingress_rule" "redis" {
  security_group_id            = aws_security_group.redis.id
  referenced_security_group_id = var.node_security_group_id
  from_port                    = 6379
  to_port                      = 6379
  ip_protocol                  = "tcp"
  description                  = "Redis from EKS nodes"
}

# ---------------------------------------------------------------------------
# PostgreSQL
# ---------------------------------------------------------------------------

resource "aws_db_parameter_group" "this" {
  name   = "${var.cluster_name}-gitlab-pg17"
  family = "postgres17"

  # GitLab requires the pg_trgm and btree_gist extensions. Preloading is not
  # required for either, but forcing SSL is, since the chart connects with
  # sslmode=require.
  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }

  tags = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_db_instance" "this" {
  identifier = "${var.cluster_name}-gitlab"

  engine         = "postgres"
  engine_version = var.db_engine_version
  instance_class = var.db_instance_class

  allocated_storage     = var.db_allocated_storage
  max_allocated_storage = var.db_allocated_storage * 4
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = local.db_name
  username = local.db_username
  password = random_password.db.result
  port     = 5432

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.db.id]
  parameter_group_name   = aws_db_parameter_group.this.name
  publicly_accessible    = false

  multi_az                = var.db_multi_az
  backup_retention_period = 7
  backup_window           = "03:00-04:00"
  maintenance_window      = "Mon:04:00-Mon:05:00"

  auto_minor_version_upgrade = true
  deletion_protection        = var.db_deletion_protection
  skip_final_snapshot        = !var.db_deletion_protection
  final_snapshot_identifier  = var.db_deletion_protection ? "${var.cluster_name}-gitlab-final" : null

  performance_insights_enabled = true
  apply_immediately            = true

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Redis
# ---------------------------------------------------------------------------

resource "aws_elasticache_replication_group" "this" {
  replication_group_id = "${var.cluster_name}-gitlab"
  description          = "GitLab Redis"

  engine         = "redis"
  engine_version = var.redis_engine_version
  node_type      = var.redis_node_type
  port           = 6379

  # Single shard, no cluster mode: GitLab expects a plain Redis endpoint.
  num_cache_clusters         = 1
  automatic_failover_enabled = false

  subnet_group_name  = aws_elasticache_subnet_group.this.name
  security_group_ids = [aws_security_group.redis.id]

  # TLS + AUTH. The chart is told scheme=rediss to match (see release.tf).
  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  auth_token                 = random_password.redis.result

  maintenance_window       = "mon:05:00-mon:06:00"
  snapshot_retention_limit = 3

  apply_immediately = true

  tags = var.tags
}
