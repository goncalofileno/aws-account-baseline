module "tags" {
  source = "../modules/tags"

  component   = "tf-state"
  environment = "shared"
  repository  = "github.com/goncalofileno/aws-account-baseline"
}

provider "aws" {
  region = var.region

  default_tags {
    tags = module.tags.tags
  }
}

data "aws_caller_identity" "current" {}

module "state_bucket" {
  source = "../modules/secure-bucket"

  name                               = "gf-tfstate-${data.aws_caller_identity.current.account_id}"
  noncurrent_version_expiration_days = 90
}
