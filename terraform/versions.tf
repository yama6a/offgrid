# Terraform for the shared off-cluster backup bucket. Greenfield: this is the repo's ONLY Terraform.
# State is LOCAL (backend below) — no remote/locking backend for now (single operator, homelab). The state
# file holds the generated IAM secret key, so it is SENSITIVE and gitignored (see terraform/.gitignore).
# Driven by lib/shell/13_s3_backup_bucket.sh, which exports the AWS deployer creds + TF_VAR_* from .env.
terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Local state on purpose (see header). `.terraform.lock.hcl` IS committed (provider pin, not sensitive);
  # terraform.tfstate* is NOT (contains the IAM secret key).
  backend "local" {}
}

provider "aws" {
  region = var.region
  # Access key + secret come from the environment (AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY), exported by
  # 13_s3_backup_bucket.sh from the .env deployer creds — never hardcoded here or in a committed tfvars.
}
