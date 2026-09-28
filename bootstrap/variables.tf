variable "region" {
  description = "AWS region for the state bucket."
  type        = string
  default     = "eu-north-1"

  validation {
    condition     = contains(["eu-north-1", "us-east-1", "us-west-2"], var.region)
    error_message = "region must be eu-north-1, us-east-1 or us-west-2: the account's AWS-managed SCP (region floor) denies requests outside these regions (plus global/unspecified)."
  }
}
