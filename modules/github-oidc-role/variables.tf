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

variable "github_owner_id" {
  description = "Numeric GitHub ID of the owner. GitHub Actions OIDC uses immutable subjects (repo:<owner>@<owner_id>/<repo>@<repo_id>:<claim>), so an owner rename or a different account reusing the name cannot inherit access."
  type        = number

  validation {
    condition     = var.github_owner_id > 0 && var.github_owner_id == floor(var.github_owner_id)
    error_message = "github_owner_id must be a positive whole number."
  }
}

variable "github_repo" {
  description = "GitHub repository name."
  type        = string
}

variable "github_repo_id" {
  description = "Numeric GitHub ID of the repository. Part of the immutable OIDC subject, so a renamed, deleted and re-created, or transferred repo with the same name cannot inherit access. Find it with: gh api repos/OWNER/REPO/actions/oidc/customization/sub -q .sub_claim_prefix"
  type        = number

  validation {
    condition     = var.github_repo_id > 0 && var.github_repo_id == floor(var.github_repo_id)
    error_message = "github_repo_id must be a positive whole number."
  }
}

variable "subject_claims" {
  description = "Allowed OIDC subject suffixes after 'repo:<owner>@<owner_id>/<repo>@<repo_id>:', e.g. 'ref:refs/heads/main', 'pull_request', 'environment:production'."
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
