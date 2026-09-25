variable "name" {
  description = "IAM role name."
  type        = string
}

variable "description" {
  description = "IAM role description."
  type        = string
  default     = ""
}

variable "oidc_provider_arn" {
  description = "ARN of the GitHub Actions OIDC provider in this account."
  type        = string
}

variable "github_owner" {
  description = "GitHub user or organisation (case-sensitive)."
  type        = string
}

variable "github_repo" {
  description = "GitHub repository name."
  type        = string
}

variable "subject_claims" {
  description = "Allowed OIDC subject suffixes after 'repo:<owner>/<repo>:', e.g. 'ref:refs/heads/main', 'pull_request', 'environment:production'."
  type        = list(string)

  validation {
    condition     = length(var.subject_claims) > 0 && alltrue([for c in var.subject_claims : !strcontains(c, "*") && !strcontains(c, "?")])
    error_message = "subject_claims must be non-empty and must not contain wildcards."
  }
}

variable "policy_json" {
  description = "Inline IAM policy (JSON) granted to the role."
  type        = string
}

variable "permissions_boundary_arn" {
  description = "Optional permissions boundary policy ARN."
  type        = string
  default     = null
}

variable "max_session_duration" {
  description = "Maximum session duration in seconds."
  type        = number
  default     = 3600
}
