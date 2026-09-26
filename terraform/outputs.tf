# The 10b to 10e scripts read these with `terraform output -raw <name>` and seal them into the cluster.
output "bucket" {
  description = "The backup bucket name."
  value       = aws_s3_bucket.backups.id
}

output "backup_access_key_id" {
  description = "Access key ID of the scoped backup-writer IAM user."
  value       = aws_iam_access_key.backup_writer.id
}

output "backup_secret_access_key" {
  description = "Secret access key of the scoped backup-writer IAM user. It is sealed into the cluster and never committed."
  value       = aws_iam_access_key.backup_writer.secret
  sensitive   = true
}
