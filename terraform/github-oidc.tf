# This creates an IAM role that GitHub Actions can assume
# Run this once, then you can remove the file

variable "github_repository" {
  description = "GitHub repository in format 'owner/repo'"
  type        = string
  default     = "Aditi-Kulkarni-PA/digital-twin"
}

variable "manage_github_oidc_resources" {
  description = "Create/manage GitHub OIDC provider and deploy role (one-time bootstrap)"
  type        = bool
  default     = true
}

locals {
  github_owner = split("/", var.github_repository)[0]
  github_repo  = split("/", var.github_repository)[1]
}

# Note: aws_caller_identity.current is already defined in main.tf

# GitHub OIDC Provider
# Note: If this already exists in your account, you'll need to import it:
# terraform import aws_iam_openid_connect_provider.github arn:aws:iam::ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com
resource "aws_iam_openid_connect_provider" "github" {
  count = var.manage_github_oidc_resources ? 1 : 0
  url = "https://token.actions.githubusercontent.com"
  
  client_id_list = [
    "sts.amazonaws.com"
  ]
  
  # This thumbprint is from GitHub's documentation
  # Verify current value at: https://github.blog/changelog/2023-06-27-github-actions-update-on-oidc-integration-with-aws/
  thumbprint_list = [
    "1b511abead59c6ce207077c0bf0e0043b1382612"
  ]
}

# IAM Role for GitHub Actions
resource "aws_iam_role" "github_actions" {
  count = var.manage_github_oidc_resources ? 1 : 0
  name = "github-actions-twin-deploy"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.github[0].arn
        }
        Action = [
          "sts:AssumeRoleWithWebIdentity",
          "sts:TagSession"
        ]
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          StringLike = {
            # GitHub can issue branch-based subjects (ref:refs/heads/main)
            # or environment-based subjects (environment:dev/test/prod).
            # Also allow lowercase owner/repo variants to avoid case mismatch issues.
            "token.actions.githubusercontent.com:sub" = [
              "repo:${var.github_repository}:*",
              "repo:${var.github_repository}:ref:refs/heads/main",
              "repo:${var.github_repository}:environment:dev",
              "repo:${var.github_repository}:environment:test",
              "repo:${var.github_repository}:environment:prod",
              "repo:${local.github_owner}@*/${local.github_repo}@*:ref:refs/heads/main",
              "repo:${local.github_owner}@*/${local.github_repo}@*:environment:dev",
              "repo:${local.github_owner}@*/${local.github_repo}@*:environment:test",
              "repo:${local.github_owner}@*/${local.github_repo}@*:environment:prod",
              "repo:${lower(var.github_repository)}:*",
              "repo:${lower(var.github_repository)}:ref:refs/heads/main",
              "repo:${lower(var.github_repository)}:environment:dev",
              "repo:${lower(var.github_repository)}:environment:test",
              "repo:${lower(var.github_repository)}:environment:prod",
              "repo:${lower(local.github_owner)}@*/${lower(local.github_repo)}@*:ref:refs/heads/main",
              "repo:${lower(local.github_owner)}@*/${lower(local.github_repo)}@*:environment:dev",
              "repo:${lower(local.github_owner)}@*/${lower(local.github_repo)}@*:environment:test",
              "repo:${lower(local.github_owner)}@*/${lower(local.github_repo)}@*:environment:prod"
            ]
          }
        }
      }
    ]
  })
  
  tags = {
    Name        = "GitHub Actions Deploy Role"
    Repository  = var.github_repository
    ManagedBy   = "terraform"
  }
}

# Attach necessary policies
resource "aws_iam_role_policy_attachment" "github_lambda" {
  count      = var.manage_github_oidc_resources ? 1 : 0
  policy_arn = "arn:aws:iam::aws:policy/AWSLambda_FullAccess"
  role       = aws_iam_role.github_actions[0].name
}

resource "aws_iam_role_policy_attachment" "github_s3" {
  count      = var.manage_github_oidc_resources ? 1 : 0
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3FullAccess"
  role       = aws_iam_role.github_actions[0].name
}

resource "aws_iam_role_policy_attachment" "github_apigateway" {
  count      = var.manage_github_oidc_resources ? 1 : 0
  policy_arn = "arn:aws:iam::aws:policy/AmazonAPIGatewayAdministrator"
  role       = aws_iam_role.github_actions[0].name
}

resource "aws_iam_role_policy_attachment" "github_cloudfront" {
  count      = var.manage_github_oidc_resources ? 1 : 0
  policy_arn = "arn:aws:iam::aws:policy/CloudFrontFullAccess"
  role       = aws_iam_role.github_actions[0].name
}

resource "aws_iam_role_policy_attachment" "github_iam_read" {
  count      = var.manage_github_oidc_resources ? 1 : 0
  policy_arn = "arn:aws:iam::aws:policy/IAMReadOnlyAccess"
  role       = aws_iam_role.github_actions[0].name
}

resource "aws_iam_role_policy_attachment" "github_bedrock" {
  count      = var.manage_github_oidc_resources ? 1 : 0
  policy_arn = "arn:aws:iam::aws:policy/AmazonBedrockFullAccess"
  role       = aws_iam_role.github_actions[0].name
}

resource "aws_iam_role_policy_attachment" "github_dynamodb" {
  count      = var.manage_github_oidc_resources ? 1 : 0
  policy_arn = "arn:aws:iam::aws:policy/AmazonDynamoDBFullAccess"
  role       = aws_iam_role.github_actions[0].name
}

resource "aws_iam_role_policy_attachment" "github_acm" {
  count      = var.manage_github_oidc_resources ? 1 : 0
  policy_arn = "arn:aws:iam::aws:policy/AWSCertificateManagerFullAccess"
  role       = aws_iam_role.github_actions[0].name
}

resource "aws_iam_role_policy_attachment" "github_route53" {
  count      = var.manage_github_oidc_resources ? 1 : 0
  policy_arn = "arn:aws:iam::aws:policy/AmazonRoute53FullAccess"
  role       = aws_iam_role.github_actions[0].name
}

# Custom policy for additional permissions
resource "aws_iam_role_policy" "github_additional" {
  count = var.manage_github_oidc_resources ? 1 : 0
  name = "github-actions-additional"
  role = aws_iam_role.github_actions[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "iam:CreateRole",
          "iam:DeleteRole",
          "iam:AttachRolePolicy",
          "iam:DetachRolePolicy",
          "iam:PutRolePolicy",
          "iam:DeleteRolePolicy",
          "iam:GetRole",
          "iam:GetRolePolicy",
          "iam:ListRolePolicies",
          "iam:ListAttachedRolePolicies",
          "iam:UpdateAssumeRolePolicy",
          "iam:PassRole",
          "iam:TagRole",
          "iam:UntagRole",
          "iam:ListInstanceProfilesForRole",
          "sts:GetCallerIdentity"
        ]
        Resource = "*"
      }
    ]
  })
}

output "github_actions_role_arn" {
  value = var.manage_github_oidc_resources ? aws_iam_role.github_actions[0].arn : ""
}