variable "component" {
  description = "Value for the Component tag: which piece of the cv-site portfolio this resource belongs to."
  type        = string

  validation {
    condition     = contains(["tf-state", "account-baseline", "web", "contact-api", "dns"], var.component)
    error_message = "component must be one of: tf-state, account-baseline, web, contact-api, dns."
  }
}

variable "environment" {
  description = "Value for the Environment tag."
  type        = string

  validation {
    condition     = contains(["prod", "shared"], var.environment)
    error_message = "environment must be prod or shared."
  }
}

variable "managed_by" {
  description = "Value for the ManagedBy tag: the IaC tool that owns this resource."
  type        = string
  default     = "terraform"

  validation {
    condition     = contains(["terraform", "pulumi"], var.managed_by)
    error_message = "managed_by must be terraform or pulumi."
  }
}

variable "repository" {
  description = "Value for the Repository tag: github.com/goncalofileno/<repo>."
  type        = string

  validation {
    condition     = can(regex("^github\\.com/goncalofileno/[A-Za-z0-9._-]+$", var.repository))
    error_message = "repository must match github.com/goncalofileno/<repo> (letters, digits, dots, underscores and hyphens only)."
  }
}
