output "tags" {
  description = "Standard tag map (Project, Component, Environment, ManagedBy, Repository, Owner) for a provider's default_tags."
  value       = local.tags
}
