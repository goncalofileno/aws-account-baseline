module "tags" {
  source = "./modules/tags"

  component   = "account-baseline"
  environment = "shared"
  repository  = "github.com/${var.github_owner}/${var.baseline_repo}"
}

provider "aws" {
  region = var.region

  default_tags {
    tags = module.tags.tags
  }
}
