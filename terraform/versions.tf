# The repo's only Terraform, driven by lib/shell/10a_s3_backup_bucket.sh, which exports the AWS deployer creds
# and TF_VAR_* from .env.
terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Local state: single operator, no remote backend. terraform.tfstate holds the generated IAM secret key, so
  # it is gitignored. .terraform.lock.hcl IS committed: a provider pin, not a secret.
  backend "local" {}
}

provider "aws" {
  region = var.region
  # Creds come from AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY, exported by 10a_s3_backup_bucket.sh. Never
  # hardcoded here or in a committed tfvars.
}
