# The shared backup bucket plus a scoped IAM writer. Four consumers, one prefix each: cnpg/, redis/,
# longhorn/, vm/.
# Lifecycle is PER-PREFIX because the consumers need different retention, and one of them cannot be expired at
# all. See the longhorn/ rule below.

resource "aws_s3_bucket" "backups" {
  bucket = var.bucket

  # The safety backstop: `make s3-backup-destroy`, or any rebuild that tried to wipe TF, FAILS rather than
  # silently deleting backups a restore might need. Flip to true only to genuinely discard every backup.
  force_destroy = false
}

resource "aws_s3_bucket_public_access_block" "backups" {
  bucket                  = aws_s3_bucket.backups.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# SSE-S3, not SSE-KMS: nothing to manage, and Barman already requests AES256 on upload (pg-cluster values), so
# the two agree.
resource "aws_s3_bucket_server_side_encryption_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Off: these objects are already immutable, so noncurrent versions would only stack cost and complicate the
# age-based expiry below.
resource "aws_s3_bucket_versioning" "backups" {
  bucket = aws_s3_bucket.backups.id
  versioning_configuration {
    status = "Disabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id

  # Straight to Glacier IR, skipping Standard-IA: IA cannot be transitioned to before 30d anyway, and its
  # 128 KB min-billable-size plus retrieval fees punish the churny small WAL objects.
  rule {
    id     = "cnpg-tier-and-expire"
    status = "Enabled"
    filter { prefix = "cnpg/" }

    transition {
      days          = var.transition_days
      storage_class = "GLACIER_IR"
    }
    expiration {
      days = var.retention_days
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  rule {
    id     = "redis-tier-and-expire"
    status = "Enabled"
    filter { prefix = "redis/" }

    transition {
      days          = var.transition_days
      storage_class = "GLACIER_IR"
    }
    expiration {
      days = var.retention_days
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  rule {
    id     = "vm-tier-and-expire"
    status = "Enabled"
    filter { prefix = "vm/" }

    transition {
      days          = var.transition_days
      storage_class = "GLACIER_IR"
    }
    expiration {
      days = var.retention_days
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  # NO transition and NO expiration, deliberately. Longhorn backups are INCREMENTAL dedup block chains: a
  # newer backup references older blocks, so an age-based expiry would delete still-referenced blocks and
  # corrupt restores. Longhorn's own RecurringJob `retain` is the sole deleter. We only clean up parts
  # orphaned by an aborted upload.
  rule {
    id     = "longhorn-abort-incomplete"
    status = "Enabled"
    filter { prefix = "longhorn/" }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.backups]
}

# The in-cluster backup clients get this identity, never the powerful .env DEPLOYER creds that run this
# Terraform. Its access key is a TF output the 14-17 scripts seal into the cluster.
resource "aws_iam_user" "backup_writer" {
  name = "${var.bucket}-writer"
  # IAM tag values allow only [\p{L}\p{Z}\p{N}_.:/=+\-@], so no parens and no commas.
  tags = { purpose = "raspi-cluster backups - barman-cloud/longhorn/redis/vm" }
}

resource "aws_iam_access_key" "backup_writer" {
  user = aws_iam_user.backup_writer.name
}

# Least privilege. Barman needs all four verbs: it lists, uploads, reads on restore, and prunes on its own
# catalog ops even with S3-owned retention.
resource "aws_iam_user_policy" "backup_writer" {
  name = "backups-rw"
  user = aws_iam_user.backup_writer.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ListBucket"
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource = aws_s3_bucket.backups.arn
      },
      {
        Sid      = "ObjectRW"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "${aws_s3_bucket.backups.arn}/*"
      },
    ]
  })
}
