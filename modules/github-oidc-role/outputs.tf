output "arn" {
  description = "Role ARN (use as role-to-assume in GitHub Actions)."
  value       = aws_iam_role.this.arn
}

output "name" {
  description = "Role name."
  value       = aws_iam_role.this.name
}

output "assume_role_policy" {
  description = "Trust policy JSON."
  value       = local.assume_role_policy
}

output "policy" {
  description = "Inline permissions policy JSON."
  value       = var.policy_json
}
