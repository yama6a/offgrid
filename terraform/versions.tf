terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Local state, because there is one operator. It holds the IAM secret key, so it is gitignored.
  backend "local" {}
}

provider "aws" {
  region = var.region
  # 10a_s3_backup_bucket.sh exports the creds. Never put them here.
}
