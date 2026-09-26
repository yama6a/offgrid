# One bucket, one prefix per consumer: cnpg/, redis/, longhorn/ and vm/. Each prefix has its own lifecycle rule,
# because the consumers need different retention.

resource "aws_s3_bucket" "backups" {
  bucket = var.bucket

  # terraform destroy fails on a bucket that still holds objects, so no rebuild deletes backups by accident.
  # `make s3-backup-destroy` empties the bucket first on purpose. Set true only to discard every backup.
  force_destroy = false
}

resource "aws_s3_bucket_public_access_block" "backups" {
  bucket                  = aws_s3_bucket.backups.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# SSE-S3, because it needs no key management. The pg-cluster ObjectStore requests the same AES256.
resource "aws_s3_bucket_server_side_encryption_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Off. Backup objects never change, so versions would only add cost.
resource "aws_s3_bucket_versioning" "backups" {
  bucket = aws_s3_bucket.backups.id
  versioning_configuration {
    status = "Disabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id

  # Straight to Glacier IR, not Standard-IA. S3 cannot move objects to IA before 30 days. IA also bills each
  # object as at least 128 KB and charges retrieval fees, which is expensive for many small WAL objects.
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

  # Never expire: newer Longhorn backups reference older blocks, so age-based expiry corrupts restores.
  # Longhorn's RecurringJob `retain` deletes backups. This rule only removes aborted uploads.
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

# The in-cluster backup identity, so the .env deployer creds never enter the cluster.
resource "aws_iam_user" "backup_writer" {
  name = "${var.bucket}-writer"
  # IAM tag values allow only [\p{L}\p{Z}\p{N}_.:/=+\-@], so no parentheses and no commas.
  tags = { purpose = "offgrid backups - barman-cloud/longhorn/redis/vm" }
}

resource "aws_iam_access_key" "backup_writer" {
  user = aws_iam_user.backup_writer.name
}

# Barman needs all four verbs. It deletes during its own catalog operations, even though S3 owns retention.
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
