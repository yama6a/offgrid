# The shared backup bucket + a scoped IAM writer. General-purpose, three consumers by prefix:
#   cnpg/     CNPG WAL/base backups   (lib/helm/pg-cluster + 14_cnpg_backup.sh)
#   redis/    Redis RDB dumps         (07_redis_backup   + 15_redis_backup.sh)
#   longhorn/ Longhorn volume backups (02_longhorn       + 16_longhorn_backup.sh)
# Lifecycle is PER-PREFIX (not one bucket-wide rule) because the consumers need different retention:
#   cnpg/ + redis/  -> Standard -> Glacier IR @transition_days -> delete @retention_days. Their objects are
#                      self-contained (WAL/base/RDB), so age-expiry is safe and S3 owns retention.
#   longhorn/       -> Standard, NEVER auto-expired. Longhorn backups are INCREMENTAL dedup block chains: a
#                      newer backup references older blocks, so an age-based expiry would delete still-referenced
#                      blocks and corrupt restores. Longhorn's own RecurringJob `retain` is the sole deleter.
# See docs/13_backups.md.

resource "aws_s3_bucket" "backups" {
  bucket = var.bucket

  # Refuse to delete a non-empty bucket. This is the safety backstop: `make s3-backup-destroy` (and any
  # rebuild that tried to wipe TF) will FAIL rather than silently delete the backups a restore might need.
  # Flip to true only when you genuinely intend to discard every backup.
  force_destroy = false
}

# Block every form of public access — backups must never be internet-readable.
resource "aws_s3_bucket_public_access_block" "backups" {
  bucket                  = aws_s3_bucket.backups.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# SSE at rest with AWS-managed keys (SSE-S3 / AES256) — decision 5. Barman also requests AES256 on upload
# (pg-cluster values wal.encryption/data.encryption), so the two agree; no SSE-KMS to manage.
resource "aws_s3_bucket_server_side_encryption_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Versioning off: backups are already immutable WAL/base objects; noncurrent versions would only stack cost
# and complicate the age-based expiry below.
resource "aws_s3_bucket_versioning" "backups" {
  bucket = aws_s3_bucket.backups.id
  versioning_configuration {
    status = "Disabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id

  # cnpg/ — self-contained WAL/base objects. Written as Standard (Barman sets no storage class); we skip
  # Standard-IA (can't transition before 30d anyway, and IA's 128 KB min-billable-size + retrieval fees punish
  # the churny small WAL objects) and go straight to Glacier Instant Retrieval, then expire. S3 owns retention.
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

  # redis/ — self-contained RDB dumps; same tier-and-expire as cnpg/ (S3 owns Redis's retention entirely).
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

  # longhorn/ — incremental block chains: NO transition, NO expiration (see header). Longhorn's RecurringJob
  # `retain` prunes backups + their now-unreferenced blocks. We only clean up parts orphaned by an aborted upload.
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

# Dedicated, bucket-scoped writer identity for the in-cluster backup clients (Barman today). Its access key is
# a TF output; 14_cnpg_backup.sh reads it and seals it into the cluster. The powerful .env DEPLOYER creds that
# run this Terraform never enter the cluster.
resource "aws_iam_user" "backup_writer" {
  name = "${var.bucket}-writer"
  # IAM tag values allow only [\p{L}\p{Z}\p{N}_.:/=+\-@] — no parens or commas.
  tags = { purpose = "raspi-cluster backups - barman-cloud/longhorn/redis" }
}

resource "aws_iam_access_key" "backup_writer" {
  user = aws_iam_user.backup_writer.name
}

# Least privilege: list the bucket + read/write/delete objects in it, nothing else. Barman needs all four
# (it lists, uploads WAL/base, reads on restore, and prunes on its own catalog ops even with S3-owned retention).
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
