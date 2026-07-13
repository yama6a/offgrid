# The shared backup bucket + a scoped IAM writer. General-purpose: CNPG WAL/base backups land under cnpg/
# today (see lib/helm/pg-cluster + 14_cnpg_backup.sh); longhorn/ and redis/ prefixes are reserved for later.
# One bucket-wide lifecycle governs ALL prefixes: land in Standard -> Glacier IR at transition_days -> delete
# at retention_days. Retention is owned HERE (S3 lifecycle), not by Barman. See docs/13_backups.md.

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

  rule {
    id     = "backups-tier-and-expire"
    status = "Enabled"
    filter {} # whole bucket (all prefixes: cnpg/, future longhorn/, redis/)

    # Objects are WRITTEN as Standard (Barman/clients don't set a storage class). We do NOT transition to
    # Standard-IA: lifecycle can't move to IA before 30d anyway, and IA's 128 KB min-billable-size + retrieval
    # fees punish the churny small WAL objects. Straight to Glacier Instant Retrieval instead.
    transition {
      days          = var.transition_days
      storage_class = "GLACIER_IR"
    }

    expiration {
      days = var.retention_days
    }

    # Barman uploads base backups via S3 multipart; clean up parts orphaned by an aborted/failed backup.
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
