
# Accepted trade-offs for this module, each recorded as a checkov skip on the bucket below.
resource "aws_s3_bucket" "this" {
  #checkov:skip=CKV_AWS_18:No access logging; it would need a second bucket per bucket, for buckets that only hold Terraform state or CloudTrail logs
  #checkov:skip=CKV_AWS_144:No cross-region replication; ongoing storage cost for personal-account data that doesn't need it (and the account's SCP limits regions)
  #checkov:skip=CKV_AWS_145:SSE-S3 (AES256) instead of a customer-managed KMS key; a CMK costs about USD 1/month and SSE-S3 already encrypts at rest
  #checkov:skip=CKV2_AWS_62:No event notifications; nothing in this account consumes them
  bucket = var.name
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket = aws_s3_bucket.this.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    id     = "expire-old-data"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_expiration_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }

    dynamic "expiration" {
      for_each = var.current_version_expiration_days == null ? [] : [var.current_version_expiration_days]
      content {
        days = expiration.value
      }
    }
  }

  depends_on = [aws_s3_bucket_versioning.this]
}

locals {
  deny_insecure_transport = {
    Sid       = "DenyInsecureTransport"
    Effect    = "Deny"
    Principal = "*"
    Action    = "s3:*"
    Resource  = [aws_s3_bucket.this.arn, "${aws_s3_bucket.this.arn}/*"]
    Condition = { Bool = { "aws:SecureTransport" = "false" } }
  }
}

resource "aws_s3_bucket_policy" "this" {
  bucket = aws_s3_bucket.this.id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = concat([local.deny_insecure_transport], var.extra_policy_statements)
  })

  depends_on = [aws_s3_bucket_public_access_block.this]
}
