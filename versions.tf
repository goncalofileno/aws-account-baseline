terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Bucket is supplied at init time: -backend-config="bucket=gf-tfstate-<account-id>"
  backend "s3" {
    key          = "aws-account-baseline/terraform.tfstate"
    region       = "eu-west-1"
    encrypt      = true
    use_lockfile = true
  }
}
