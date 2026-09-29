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
