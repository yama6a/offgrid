# lib/shell/10a_s3_backup_bucket.sh exports every value from .env as TF_VAR_*. No tfvars file is committed.
variable "region" {
  description = "AWS region for the backup bucket (.env AWS_REGION)."
  type        = string
}

variable "bucket" {
  description = "Globally unique S3 bucket name for all cluster backups (.env S3_BACKUP_BUCKET)."
  type        = string
}

variable "transition_days" {
  description = "Age in days at which objects move to Glacier Instant Retrieval (.env S3_BACKUP_TRANSITION_DAYS)."
  type        = number
  default     = 30
}

variable "retention_days" {
  description = "Age in days at which S3 deletes objects. This is the recovery window (.env S3_BACKUP_RETENTION_DAYS)."
  type        = number
  default     = 180
}
