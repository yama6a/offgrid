# lib/shell/10a_s3_backup_bucket.sh runs this Terraform. It exports the AWS deployer creds and TF_VAR_* from
# .env.
terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Local state, because there is one operator. terraform.tfstate holds the generated IAM secret key, so it is
  # gitignored. .terraform.lock.hcl is committed, because it is a provider pin and holds no secret.
  backend "local" {}
}

provider "aws" {
  region = var.region
  # 10a_s3_backup_bucket.sh exports the creds as AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY. Never put them
  # here or in a committed tfvars file.
}
