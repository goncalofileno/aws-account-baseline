output "cv_site_deploy_role_arn" {
  description = "Set as AWS_ROLE_DEPLOY in the cv-site GitHub repo variables."
  value       = module.cv_site_deploy.arn
}

output "cv_site_preview_role_arn" {
  description = "Set as AWS_ROLE_PREVIEW in the cv-site GitHub repo variables."
  value       = module.cv_site_preview.arn
}

output "baseline_plan_role_arn" {
  description = "Set as AWS_ROLE_PLAN in this repo's GitHub variables."
  value       = module.baseline_plan.arn
}

output "baseline_apply_role_arn" {
  description = "Set as AWS_ROLE_APPLY in this repo's GitHub variables."
  value       = module.baseline_apply.arn
}

output "cloudtrail_bucket" {
  description = "S3 bucket receiving CloudTrail logs."
  value       = module.cloudtrail_bucket.name
}
