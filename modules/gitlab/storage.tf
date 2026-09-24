###############################################################################
# GitLab object storage -- S3 + IRSA.
#
# Chart v10 requires external object storage; there is no bundled MinIO to
# fall back to. Access is via IRSA (use_iam_profile) rather than a static
# access key in a Secret, which is the pattern the rest of this stack uses.
###############################################################################

data "aws_caller_identity" "current" {}

locals {
  # Bucket names are globally unique across all of AWS, hence the account id.
  bucket_suffix = "${var.cluster_name}-${data.aws_caller_identity.current.account_id}"

  buckets = {
    artifacts       = "gitlab-artifacts-${local.bucket_suffix}"
    lfs             = "gitlab-lfs-${local.bucket_suffix}"
    uploads         = "gitlab-uploads-${local.bucket_suffix}"
    packages        = "gitlab-packages-${local.bucket_suffix}"
    backups         = "gitlab-backups-${local.bucket_suffix}"
    tmp             = "gitlab-tmp-${local.bucket_suffix}"
    registry        = "gitlab-registry-${local.bucket_suffix}"
    ciSecureFiles   = "gitlab-ci-secure-files-${local.bucket_suffix}"
    dependencyProxy = "gitlab-dependency-proxy-${local.bucket_suffix}"
    terraformState  = "gitlab-tf-state-${local.bucket_suffix}"
    externalDiffs   = "gitlab-mr-diffs-${local.bucket_suffix}"
    pages           = "gitlab-pages-${local.bucket_suffix}"
  }

  bucket_names = { for k, b in aws_s3_bucket.this : k => b.id }
}

resource "aws_s3_bucket" "this" {
  for_each = local.buckets

  bucket = each.value
  tags   = merge(var.tags, { GitLabPurpose = each.key })
}

resource "aws_s3_bucket_public_access_block" "this" {
  for_each = local.buckets

  bucket                  = aws_s3_bucket.this[each.key].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  for_each = local.buckets

  bucket = aws_s3_bucket.this[each.key].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "this" {
  for_each = local.buckets

  bucket = aws_s3_bucket.this[each.key].id

  versioning_configuration {
    status = "Enabled"
  }
}

# Backups and the backup scratch bucket grow without bound otherwise.
resource "aws_s3_bucket_lifecycle_configuration" "backups" {
  for_each = { for k, v in local.buckets : k => v if contains(["backups", "tmp"], k) }

  bucket = aws_s3_bucket.this[each.key].id

  rule {
    id     = "expire-old-backups"
    status = "Enabled"

    filter {}

    expiration {
      days = each.key == "tmp" ? 7 : 90
    }

    noncurrent_version_expiration {
      noncurrent_days = 7
    }
  }
}

# ---------------------------------------------------------------------------
# IRSA role assumed by every GitLab service account in the namespace
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "s3_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    # The chart creates a separate ServiceAccount per component (webservice,
    # sidekiq, toolbox, registry, ...), so this is scoped by namespace rather
    # than enumerating every name the chart might add.
    condition {
      test     = "StringLike"
      variable = "${var.oidc_provider}:sub"
      values   = ["system:serviceaccount:${var.namespace}:*"]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "s3" {
  name               = "${var.cluster_name}-gitlab-s3"
  assume_role_policy = data.aws_iam_policy_document.s3_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy" "s3" {
  name = "gitlab-object-storage"
  role = aws_iam_role.s3.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation", "s3:ListBucketMultipartUploads"]
        Resource = [for b in aws_s3_bucket.this : b.arn]
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:AbortMultipartUpload",
          "s3:ListMultipartUploadParts",
        ]
        Resource = [for b in aws_s3_bucket.this : "${b.arn}/*"]
      },
    ]
  })
}
