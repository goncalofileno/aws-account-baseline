variable "github_owner" {
  description = "GitHub user that owns the repositories. Case-sensitive: it must match the OIDC sub claim."
  type        = string
  default     = "goncalofileno"

  validation {
    condition     = can(regex("^[A-Za-z0-9-]+$", var.github_owner))
    error_message = "github_owner must be a GitHub login (letters, digits and hyphens only)."
  }
}

variable "github_owner_id" {
  description = "Numeric GitHub ID of github_owner. Part of the immutable OIDC subject (public GitHub metadata, not personal data)."
  type        = number
  default     = 99756598

  validation {
    condition     = var.github_owner_id > 0 && var.github_owner_id == floor(var.github_owner_id)
    error_message = "github_owner_id must be a positive whole number."
  }
}

variable "region" {
  description = "AWS region for regional resources."
  type        = string
  default     = "eu-north-1"

  validation {
    condition     = contains(["eu-north-1", "us-east-1", "us-west-2"], var.region)
    error_message = "region must be eu-north-1, us-east-1 or us-west-2: the account's AWS-managed SCP (region floor) denies requests outside these regions (plus global/unspecified)."
  }
}

variable "baseline_repo" {
  description = "Name of this repository on GitHub."
  type        = string
  default     = "aws-account-baseline"
}

variable "baseline_repo_id" {
  description = "Numeric GitHub ID of the baseline repository. Part of the immutable OIDC subject."
  type        = number
  default     = 1394684072

  validation {
    condition     = var.baseline_repo_id > 0 && var.baseline_repo_id == floor(var.baseline_repo_id)
    error_message = "baseline_repo_id must be a positive whole number."
  }
}

variable "cv_site_repo" {
  description = "Name of the CV site repository on GitHub."
  type        = string
  default     = "cv-site"
}

variable "cv_site_repo_id" {
  description = "Numeric GitHub ID of the CV site repository. Part of the immutable OIDC subject."
  type        = number
  default     = 1386380543

  validation {
    condition     = var.cv_site_repo_id > 0 && var.cv_site_repo_id == floor(var.cv_site_repo_id)
    error_message = "cv_site_repo_id must be a positive whole number."
  }
}

variable "alert_email" {
  description = "Email address that receives AWS Budget alerts."
  type        = string
  sensitive   = true

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.alert_email))
    error_message = "alert_email must be a valid email address."
  }
}

variable "kill_switch_max_distributions" {
  description = "Most CloudFront distributions the cost kill switch tolerates. More than this trips it before any metric is read, so raise it here before adding one."
  type        = number
  default     = 1

  validation {
    condition     = var.kill_switch_max_distributions >= 1 && var.kill_switch_max_distributions == floor(var.kill_switch_max_distributions)
    error_message = "kill_switch_max_distributions must be a whole number of at least 1."
  }
}

variable "kill_switch_max_apis" {
  description = "Most HTTP APIs the cost kill switch tolerates. More than this trips it before any metric is read, so raise it here before adding one."
  type        = number
  default     = 1

  validation {
    condition     = var.kill_switch_max_apis >= 1 && var.kill_switch_max_apis == floor(var.kill_switch_max_apis)
    error_message = "kill_switch_max_apis must be a whole number of at least 1."
  }
}

variable "kill_switch_max_functions" {
  description = "Most Lambda functions, other than the kill switch itself, that the cost kill switch tolerates. More than this trips it before any metric is read, so raise it here before adding one."
  type        = number
  default     = 1

  validation {
    condition     = var.kill_switch_max_functions >= 1 && var.kill_switch_max_functions == floor(var.kill_switch_max_functions)
    error_message = "kill_switch_max_functions must be a whole number of at least 1."
  }
}

variable "kill_switch_free_cloudfront_bytes" {
  description = "Bytes of CloudFront data transfer per month the cost kill switch treats as free (the Organization-wide free allowance, 1 TB). Raising it makes the switch trip later; 0 counts every byte."
  type        = number
  default     = 1000000000000

  validation {
    condition     = var.kill_switch_free_cloudfront_bytes >= 0 && var.kill_switch_free_cloudfront_bytes == floor(var.kill_switch_free_cloudfront_bytes)
    error_message = "kill_switch_free_cloudfront_bytes must be a whole number of at least 0."
  }
}

variable "kill_switch_free_cloudfront_requests" {
  description = "CloudFront requests per month the cost kill switch treats as free (the Organization-wide free allowance, 10 million). Raising it makes the switch trip later; 0 counts every request."
  type        = number
  default     = 10000000

  validation {
    condition     = var.kill_switch_free_cloudfront_requests >= 0 && var.kill_switch_free_cloudfront_requests == floor(var.kill_switch_free_cloudfront_requests)
    error_message = "kill_switch_free_cloudfront_requests must be a whole number of at least 0."
  }
}
