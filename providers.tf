provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project    = "aws-account-baseline"
      ManagedBy  = "terraform"
      Repository = "github.com/${var.github_owner}/${var.baseline_repo}"
    }
  }
}
