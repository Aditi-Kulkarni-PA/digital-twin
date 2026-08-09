# This file creates the S3 bucket and DynamoDB table for Terraform state
# Run this once per AWS account, then remove the file

resource "aws_s3_bucket" "terraform_state" {
  count  = var.manage_backend_infra ? 1 : 0
  bucket = "twin-terraform-state-${data.aws_caller_identity.current.account_id}"
  
  tags = {
    Name        = "Terraform State Store"
    Environment = "global"
    ManagedBy   = "terraform"
  }
}

resource "aws_s3_bucket_versioning" "terraform_state" {
  count  = var.manage_backend_infra ? 1 : 0
  bucket = aws_s3_bucket.terraform_state[0].id
  
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "terraform_state" {
  count  = var.manage_backend_infra ? 1 : 0
  bucket = aws_s3_bucket.terraform_state[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "terraform_state" {
  count  = var.manage_backend_infra ? 1 : 0
  bucket = aws_s3_bucket.terraform_state[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_dynamodb_table" "terraform_locks" {
  count        = var.manage_backend_infra ? 1 : 0
  name         = "twin-terraform-locks"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  tags = {
    Name        = "Terraform State Locks"
    Environment = "global"
    ManagedBy   = "terraform"
  }
}

# Note: aws_caller_identity.current is already defined in main.tf

output "state_bucket_name" {
  value = var.manage_backend_infra ? aws_s3_bucket.terraform_state[0].id : ""
}

output "dynamodb_table_name" {
  value = var.manage_backend_infra ? aws_dynamodb_table.terraform_locks[0].name : ""
}