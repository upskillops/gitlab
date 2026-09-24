###############################################################################
# The Kubernetes side of GitLab: namespace, the four secrets the chart expects
# to already exist, and the release itself.
#
# EVERYTHING IN THIS FILE is conditional on install_method = "terraform".
# Under the default "helm" it is created by helm-charts/bin/install-gitlab.sh
# instead, from helm-charts/values/gitlab.values.yaml -- which is a direct
# transcription of the values below, so the two must be kept in step. The AWS
# resources GitLab sits on (datastores.tf, storage.tf) are NOT conditional:
# Terraform owns those in both modes, and the install script reads their
# addresses out of `terraform output`.
#
# Browser access: Envoy Gateway gets an internet-facing NLB (via the AWS Load
# Balancer Controller in the ingress module), external-dns points
# gitlab.<domain> at it, and cert-manager issues a Let's Encrypt certificate.
###############################################################################

# Ordering gate for everything below.
#
# Consuming var.k8s_dependencies inside a resource is what creates the
# dependency edge on the caller's cluster-addons and ingress modules. A
# `depends_on` on the module block would have ordered the RDS and ElastiCache
# resources too, which is exactly what we are avoiding -- they only need the
# VPC and are free to build in parallel with the cluster.
resource "terraform_data" "k8s_gate" {
  input = var.k8s_dependencies
}

resource "kubernetes_namespace_v1" "this" {
  depends_on = [terraform_data.k8s_gate]

  count = local.via_terraform ? 1 : 0

  metadata {
    name = var.namespace
  }
}

# ---------------------------------------------------------------------------
# Secrets the chart expects to already exist
# ---------------------------------------------------------------------------

resource "kubernetes_secret_v1" "postgres" {
  depends_on = [terraform_data.k8s_gate]

  count = local.via_terraform ? 1 : 0

  metadata {
    name      = "gitlab-postgres-password"
    namespace = kubernetes_namespace_v1.this[0].metadata[0].name
  }

  data = {
    password = random_password.db.result
  }
}

resource "kubernetes_secret_v1" "redis" {
  depends_on = [terraform_data.k8s_gate]

  count = local.via_terraform ? 1 : 0

  metadata {
    name      = "gitlab-redis-password"
    namespace = kubernetes_namespace_v1.this[0].metadata[0].name
  }

  data = {
    password = random_password.redis.result
  }
}

# Object storage for artifacts/LFS/uploads/packages/backups. `use_iam_profile`
# makes Fog pick up the IRSA credentials instead of a static access key.
resource "kubernetes_secret_v1" "object_storage" {
  depends_on = [terraform_data.k8s_gate]

  count = local.via_terraform ? 1 : 0

  metadata {
    name      = "gitlab-object-storage"
    namespace = kubernetes_namespace_v1.this[0].metadata[0].name
  }

  data = {
    connection = yamlencode({
      provider        = "AWS"
      region          = var.aws_region
      use_iam_profile = true
    })
  }
}

# The container registry reads its own storage config, in Docker-registry
# format rather than Fog format.
resource "kubernetes_secret_v1" "registry_storage" {
  depends_on = [terraform_data.k8s_gate]

  count = local.via_terraform ? 1 : 0

  metadata {
    name      = "gitlab-registry-storage"
    namespace = kubernetes_namespace_v1.this[0].metadata[0].name
  }

  data = {
    config = yamlencode({
      s3 = {
        bucket = local.bucket_names["registry"]
        region = var.aws_region
        v4auth = true
        # No accesskey/secretkey: the registry picks up IRSA from the pod.
      }
    })
  }
}

# ---------------------------------------------------------------------------
# GitLab
# ---------------------------------------------------------------------------

resource "helm_release" "gitlab" {
  count = local.via_terraform ? 1 : 0

  name       = "gitlab"
  namespace  = kubernetes_namespace_v1.this[0].metadata[0].name
  repository = "https://charts.gitlab.io/"
  chart      = "gitlab"
  version    = var.chart_version

  # A first install runs migrations and pulls ~20 images. Waiting is correct
  # but slow, so it is opt-in.
  wait    = var.wait_for_rollout
  timeout = 2400

  values = [
    yamlencode({
      global = {
        edition = "ce"

        hosts = {
          domain = var.domain
          https  = true
        }

        # Chart v10 fronts GitLab with Gateway API (Envoy Gateway) rather than
        # an nginx Ingress. cert-manager and the HTTP->HTTPS redirect are wired
        # up by the chart itself.
        gatewayApi = {
          enabled              = true
          installEnvoy         = true
          configureCertmanager = true
          httpToHttpsRedirect  = true
        }
        ingress = {
          enabled = false
        }

        # --- external PostgreSQL (RDS) ---
        psql = {
          host     = aws_db_instance.this.address
          port     = 5432
          database = local.db_name
          username = local.db_username
          password = {
            useSecret = true
            secret    = kubernetes_secret_v1.postgres[0].metadata[0].name
            key       = "password"
          }
        }

        # --- external Redis (ElastiCache) ---
        # scheme=rediss because the replication group has
        # transit_encryption_enabled; without it every connection is refused.
        redis = {
          host   = aws_elasticache_replication_group.this.primary_endpoint_address
          port   = 6379
          scheme = "rediss"
          auth = {
            enabled = true
            secret  = kubernetes_secret_v1.redis[0].metadata[0].name
            key     = "password"
          }
        }

        # --- external object storage (S3 via IRSA) ---
        appConfig = {
          object_store = {
            enabled        = true
            proxy_download = true
            connection = {
              secret = kubernetes_secret_v1.object_storage[0].metadata[0].name
              key    = "connection"
            }
          }
          artifacts       = { bucket = local.bucket_names["artifacts"] }
          lfs             = { bucket = local.bucket_names["lfs"] }
          uploads         = { bucket = local.bucket_names["uploads"] }
          packages        = { bucket = local.bucket_names["packages"] }
          externalDiffs   = { bucket = local.bucket_names["externalDiffs"] }
          ciSecureFiles   = { bucket = local.bucket_names["ciSecureFiles"] }
          dependencyProxy = { bucket = local.bucket_names["dependencyProxy"] }
          terraformState  = { bucket = local.bucket_names["terraformState"] }
          pages           = { bucket = local.bucket_names["pages"] }
          backups = {
            bucket    = local.bucket_names["backups"]
            tmpBucket = local.bucket_names["tmp"]
          }
        }

        # IRSA: every GitLab ServiceAccount assumes the S3 role.
        serviceAccount = {
          enabled = true
          create  = true
          annotations = {
            "eks.amazonaws.com/role-arn" = aws_iam_role.s3.arn
          }
        }

        # Honoured by _application.tpl for every GitLab component.
        nodeSelector = local.node_selector
        tolerations  = local.tolerations
      }

      # Let's Encrypt account for the chart-managed issuer.
      certmanager-issuer = {
        email = var.acme_email
      }

      # cert-manager ships with the chart; keep its pods on infra too.
      certmanager = {
        installCRDs  = true
        nodeSelector = local.node_selector
        tolerations  = local.tolerations
        webhook = {
          nodeSelector = local.node_selector
          tolerations  = local.tolerations
        }
        cainjector = {
          nodeSelector = local.node_selector
          tolerations  = local.tolerations
        }
        startupapicheck = {
          nodeSelector = local.node_selector
          tolerations  = local.tolerations
        }
      }

      # The Envoy Gateway control plane.
      "envoy-gateway" = {
        deployment = {
          pod = {
            nodeSelector = local.node_selector
            tolerations  = local.tolerations
          }
        }

        # certgen is a Helm hook Job that mints Envoy Gateway's internal certs.
        # It is the one pod the chart does not cover via global.nodeSelector,
        # and because it is a hook the whole release blocks until it completes.
        certgen = {
          job = {
            nodeSelector = local.node_selector
            tolerations  = local.tolerations
          }
        }
      }

      # This is what turns the Gateway into a browser-reachable endpoint:
      # Envoy Gateway copies these onto the Service it creates, and the AWS
      # Load Balancer Controller turns that into an internet-facing NLB.
      gatewayApiResources = {
        gateway = {
          infrastructure = {
            annotations = {
              "service.beta.kubernetes.io/aws-load-balancer-type"            = "external"
              "service.beta.kubernetes.io/aws-load-balancer-nlb-target-type" = "ip"
              "service.beta.kubernetes.io/aws-load-balancer-scheme"          = "internet-facing"
              "service.beta.kubernetes.io/aws-load-balancer-name"            = "${var.cluster_name}-gitlab"
            }
          }
        }
      }

      # Prometheus/Grafana belong on the monitoring tier, not bundled in here.
      prometheus = {
        install = false
      }

      # --- component sizing, tuned for m7g.xlarge infra nodes ---
      gitlab = {
        webservice = {
          minReplicas = var.webservice_replicas
          maxReplicas = var.webservice_replicas + 2
          resources   = { requests = { cpu = "500m", memory = "2Gi" } }
        }
        sidekiq = {
          minReplicas = var.sidekiq_replicas
          maxReplicas = var.sidekiq_replicas + 2
          resources   = { requests = { cpu = "400m", memory = "1500Mi" } }
        }
        "gitlab-shell" = {
          minReplicas = 2
          maxReplicas = 3
        }
        toolbox = {
          resources = { requests = { cpu = "100m", memory = "512Mi" } }
          # Backups run from here; it needs the S3 role too.
          backups = {
            objectStorage = {
              config = {
                secret = kubernetes_secret_v1.object_storage[0].metadata[0].name
                key    = "connection"
              }
            }
          }
        }
        gitaly = {
          persistence = {
            size = var.gitaly_storage_size
            # The infra tier's class, which is the Retain one -- this volume
            # is where git repositories actually live.
            storageClass = var.gitaly_storage_class
          }
          resources = { requests = { cpu = "500m", memory = "2Gi" } }
        }
      }

      registry = {
        enabled = true
        storage = {
          secret = kubernetes_secret_v1.registry_storage[0].metadata[0].name
          key    = "config"
        }
      }

      # --- bundled GitLab Runner ---
      # Ships with the chart and self-registers against this GitLab, which
      # avoids the usual chicken-and-egg of needing a registration token from
      # a UI that does not exist yet.
      "gitlab-runner" = {
        install = true

        # The runner *manager* sits with GitLab on stable on-demand nodes.
        nodeSelector = local.node_selector
        tolerations  = local.tolerations

        rbac = {
          create = true
        }

        runners = {
          # CI *job* pods are the ideal spot workload: short-lived and
          # restartable. Selecting on `workload: infra` (rather than the
          # node group label above) lets them land on either the managed
          # nodes or the Karpenter infra pool, which includes spot.
          config = <<-TOML
            [[runners]]
              [runners.kubernetes]
                namespace = "{{.Release.Namespace}}"
                image = "alpine:3.21"
                cpu_request = "500m"
                memory_request = "1Gi"
                helper_image = "${var.runner_helper_image}"
                [runners.kubernetes.node_selector]
                  "workload" = "infra"
                  "kubernetes.io/arch" = "arm64"
                [[runners.kubernetes.node_tolerations]]
                  key = "workload"
                  operator = "Equal"
                  value = "infra"
                  effect = "NoSchedule"
          TOML
        }
      }
    })
  ]

  depends_on = [
    aws_db_instance.this,
    aws_elasticache_replication_group.this,
    aws_iam_role_policy.s3,
    # Addons and ingress controllers -- see terraform_data.k8s_gate above.
    terraform_data.k8s_gate,
  ]
}
