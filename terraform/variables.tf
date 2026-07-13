# All values come from .env via TF_VAR_* (exported by lib/shell/13_s3_backup_bucket.sh). No committed tfvars.
variable "region" {
  description = "AWS region for the backup bucket (.env AWS_REGION)."
  type        = string
}

variable "bucket" {
  description = "Globally-unique S3 bucket name for all cluster backups (.env S3_BACKUP_BUCKET)."
  type        = string
}

variable "transition_days" {
  description = "Age at which objects transition to Glacier Instant Retrieval (.env S3_BACKUP_TRANSITION_DAYS)."
  type        = number
  default     = 30
}

variable "retention_days" {
  description = "Age at which objects are permanently deleted; the recovery window (.env S3_BACKUP_RETENTION_DAYS)."
  type        = number
  default     = 180
}
