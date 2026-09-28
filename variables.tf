variable "github_owner" {
  description = "GitHub user that owns the repositories. Case-sensitive: it must match the OIDC sub claim."
  type        = string
  default     = "goncalofileno"

  validation {
    condition     = can(regex("^[A-Za-z0-9-]+$", var.github_owner))
    error_message = "github_owner must be a GitHub login (letters, digits and hyphens only)."
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

variable "cv_site_repo" {
  description = "Name of the CV site repository on GitHub."
  type        = string
  default     = "cv-site"
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
