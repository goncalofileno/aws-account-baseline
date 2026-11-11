# Account-level S3 Block Public Access. Nothing in the account serves S3 publicly: the site bucket is
# private behind CloudFront (OAC). The cv-site roles have no account-level S3 action, so they can't
# turn this off.
resource "aws_s3_account_public_access_block" "this" {
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
