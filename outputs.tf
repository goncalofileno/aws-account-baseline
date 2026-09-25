output "cv_site_deploy_role_arn" {
  description = "Set as AWS_ROLE_DEPLOY in the cv-site GitHub repo variables."
  value       = module.cv_site_deploy.arn
}

output "cv_site_preview_role_arn" {
  description = "Set as AWS_ROLE_PREVIEW in the cv-site GitHub repo variables."
  value       = module.cv_site_preview.arn
}
