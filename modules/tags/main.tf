# Project and Owner are constants: every resource in this portfolio belongs to the same project
# and the same owner, so callers never set them (see docs/tagging-policy.md for the full policy).
locals {
  tags = {
    Project     = "cv-site"
    Component   = var.component
    Environment = var.environment
    ManagedBy   = var.managed_by
    Repository  = var.repository
    Owner       = "goncalo-fileno"
  }
}
