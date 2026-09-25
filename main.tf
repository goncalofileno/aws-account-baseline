data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id

  # Created by bootstrap/ (same naming convention).
  state_bucket_name = "gf-tfstate-${local.account_id}"
  state_key         = "aws-account-baseline/terraform.tfstate"

  trail_name        = "baseline-management-events"
  trail_arn         = "arn:aws:cloudtrail:${var.region}:${local.account_id}:trail/${local.trail_name}"
  trail_bucket_name = "gf-cloudtrail-${local.account_id}"
}
