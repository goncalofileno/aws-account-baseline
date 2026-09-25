variable "github_owner" {
  description = "GitHub user that owns the repositories. Case-sensitive: it must match the OIDC sub claim."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9-]+$", var.github_owner))
    error_message = "github_owner must be a GitHub login (letters, digits and hyphens only)."
  }
}

variable "region" {
  description = "AWS region for regional resources."
  type        = string
  default     = "eu-west-1"
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
