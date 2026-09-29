locals {
  cloudtrail_bucket_statements = [
    {
      Sid       = "CloudTrailAclCheck"
      Effect    = "Allow"
      Principal = { Service = "cloudtrail.amazonaws.com" }
      Action    = "s3:GetBucketAcl"
      Resource  = "arn:aws:s3:::${local.trail_bucket_name}"
      Condition = { StringEquals = { "aws:SourceArn" = local.trail_arn } }
    },
    {
      Sid       = "CloudTrailWrite"
      Effect    = "Allow"
      Principal = { Service = "cloudtrail.amazonaws.com" }
      Action    = "s3:PutObject"
      Resource  = "arn:aws:s3:::${local.trail_bucket_name}/AWSLogs/${local.account_id}/*"
      Condition = { StringEquals = { "aws:SourceArn" = local.trail_arn } }
    },
  ]
}

module "cloudtrail_bucket" {
  source = "./modules/secure-bucket"

  name                               = local.trail_bucket_name
  noncurrent_version_expiration_days = 30
  current_version_expiration_days    = 90
  extra_policy_statements            = local.cloudtrail_bucket_statements
}

resource "aws_cloudtrail" "main" {
  #checkov:skip=CKV_AWS_35:Logs are encrypted with SSE-S3; a customer-managed KMS key would add USD 1/month
  #checkov:skip=CKV_AWS_252:No SNS topic; nobody consumes per-file delivery notifications
  #checkov:skip=CKV2_AWS_10:No CloudWatch Logs delivery; it costs money and nothing consumes it (event history and the S3 log files cover investigations)
  name                          = local.trail_name
  s3_bucket_name                = module.cloudtrail_bucket.name
  is_multi_region_trail         = true
  include_global_service_events = true
  enable_log_file_validation    = true

  depends_on = [module.cloudtrail_bucket]
}
