output "state_bucket" {
  description = "Name of the S3 bucket holding Terraform state for the root module."
  value       = module.state_bucket.name
}
