variable "name" {
  description = "Globally unique bucket name."
  type        = string
}

variable "noncurrent_version_expiration_days" {
  description = "Days after which noncurrent object versions are permanently deleted."
  type        = number
}

variable "current_version_expiration_days" {
  description = "Days after which current objects expire. null keeps them indefinitely."
  type        = number
  default     = null
}

variable "extra_policy_statements" {
  description = "Additional bucket policy statements, appended after the TLS-only deny statement."
  type        = any
  default     = []
}
