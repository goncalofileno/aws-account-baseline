mock_provider "aws" {}

run "hardens_bucket_by_default" {
  command = apply

  module {
    source = "./modules/secure-bucket"
  }

  variables {
    name                               = "test-bucket"
    noncurrent_version_expiration_days = 30
  }

  assert {
    condition = alltrue([
      aws_s3_bucket_public_access_block.this.block_public_acls,
      aws_s3_bucket_public_access_block.this.block_public_policy,
      aws_s3_bucket_public_access_block.this.ignore_public_acls,
      aws_s3_bucket_public_access_block.this.restrict_public_buckets,
    ])
    error_message = "All four public access block settings must be true."
  }

  assert {
    condition = anytrue([
      for s in jsondecode(aws_s3_bucket_policy.this.policy).Statement :
      s.Effect == "Deny" && try(s.Condition.Bool["aws:SecureTransport"], "") == "false"
    ])
    error_message = "Bucket policy must deny requests made without TLS."
  }

  assert {
    condition     = one(aws_s3_bucket_versioning.this.versioning_configuration).status == "Enabled"
    error_message = "Versioning must be enabled."
  }

  assert {
    condition     = one(one(aws_s3_bucket_server_side_encryption_configuration.this.rule).apply_server_side_encryption_by_default).sse_algorithm == "AES256"
    error_message = "Default encryption must be SSE-S3 (AES256)."
  }

  assert {
    condition     = one(one(aws_s3_bucket_lifecycle_configuration.this.rule).noncurrent_version_expiration).noncurrent_days == 30
    error_message = "Noncurrent versions must expire after the configured days."
  }

  assert {
    condition     = length(one(aws_s3_bucket_lifecycle_configuration.this.rule).expiration) == 0
    error_message = "Current objects must not expire unless current_version_expiration_days is set."
  }

  assert {
    condition     = one(aws_s3_bucket_ownership_controls.this.rule).object_ownership == "BucketOwnerEnforced"
    error_message = "ACLs must be disabled (BucketOwnerEnforced)."
  }

  assert {
    condition     = output.name == "test-bucket"
    error_message = "Output name must be the bucket name."
  }
}

run "supports_current_expiration_and_extra_statements" {
  command = apply

  module {
    source = "./modules/secure-bucket"
  }

  variables {
    name                               = "test-bucket"
    noncurrent_version_expiration_days = 30
    current_version_expiration_days    = 90
    extra_policy_statements = [
      {
        Sid       = "Extra"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:GetBucketAcl"
        Resource  = "arn:aws:s3:::test-bucket"
      },
    ]
  }

  assert {
    condition     = one(one(aws_s3_bucket_lifecycle_configuration.this.rule).expiration).days == 90
    error_message = "Current objects must expire after current_version_expiration_days."
  }

  assert {
    condition     = length(jsondecode(aws_s3_bucket_policy.this.policy).Statement) == 2
    error_message = "Extra statements must be appended to the TLS deny statement."
  }
}
