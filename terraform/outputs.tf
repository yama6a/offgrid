# Consumed by lib/shell/14_cnpg_backup.sh via `terraform output -raw <name>` to seal the in-cluster S3 creds.
output "bucket" {
  description = "The backup bucket name."
  value       = aws_s3_bucket.backups.id
}

output "backup_access_key_id" {
  description = "Access key ID of the scoped backup-writer IAM user."
  value       = aws_iam_access_key.backup_writer.id
}

output "backup_secret_access_key" {
  description = "Secret access key of the scoped backup-writer IAM user (sealed into the cluster, never committed)."
  value       = aws_iam_access_key.backup_writer.secret
  sensitive   = true
}
