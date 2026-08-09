variable "manage_backend_infra" {
  description = "Create Terraform backend S3 bucket and DynamoDB lock table"
  type        = bool
  default     = true
}
