provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "aws-account-baseline"
      ManagedBy = "terraform"
      Component = "bootstrap"
    }
  }
}

data "aws_caller_identity" "current" {}

module "state_bucket" {
  source = "../modules/secure-bucket"

  name                               = "gf-tfstate-${data.aws_caller_identity.current.account_id}"
  noncurrent_version_expiration_days = 90
}
