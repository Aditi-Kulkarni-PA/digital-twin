#!/bin/bash
set -e

ENVIRONMENT=${1:-dev}          # dev | test | prod
PROJECT_NAME=${2:-twin}

echo "🚀 Deploying ${PROJECT_NAME} to ${ENVIRONMENT}..."

# 1. Build Lambda package
cd "$(dirname "$0")/.."        # project root

# Load OpenAI secret ARN for Terraform from backend/.env when not already exported.
if [ -z "${TF_VAR_openai_api_key_secret_arn:-}" ] && [ -f "backend/.env" ]; then
  OPENAI_SECRET_ARN_FROM_ENV=$(grep -E '^[[:space:]]*OPENAI_API_KEY_SECRET_ARN=' backend/.env | tail -n1 | cut -d'=' -f2-)
  OPENAI_SECRET_ARN_FROM_ENV=$(echo "$OPENAI_SECRET_ARN_FROM_ENV" | sed -e "s/^['\"]//" -e "s/['\"]$//")
  if [ -n "$OPENAI_SECRET_ARN_FROM_ENV" ]; then
    export TF_VAR_openai_api_key_secret_arn="$OPENAI_SECRET_ARN_FROM_ENV"
    echo "🔐 Loaded OPENAI_API_KEY_SECRET_ARN from backend/.env for Terraform"
  fi
fi

if [ -z "${TF_VAR_openai_model_id:-}" ] && [ -f "backend/.env" ]; then
  OPENAI_MODEL_ID_FROM_ENV=$(grep -E '^[[:space:]]*OPENAI_MODEL_ID=' backend/.env | tail -n1 | cut -d'=' -f2-)
  OPENAI_MODEL_ID_FROM_ENV=$(echo "$OPENAI_MODEL_ID_FROM_ENV" | sed -e "s/^['\"]//" -e "s/['\"]$//")
  if [ -n "$OPENAI_MODEL_ID_FROM_ENV" ]; then
    export TF_VAR_openai_model_id="$OPENAI_MODEL_ID_FROM_ENV"
    echo "🧠 Loaded OPENAI_MODEL_ID from backend/.env for Terraform"
  fi
fi

if [ -z "${TF_VAR_openai_model_id:-}" ]; then
  export TF_VAR_openai_model_id="gpt-4.1-mini"
fi

if [ -z "${TF_VAR_openai_api_key_secret_arn:-}" ]; then
  echo "❌ OPENAI_API_KEY_SECRET_ARN not found in backend/.env and TF_VAR_openai_api_key_secret_arn is not set"
  exit 1
fi

echo "📦 Building Lambda package..."
(cd backend && uv run deploy.py)

# 2. Terraform init & apply
cd terraform
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION=${DEFAULT_AWS_REGION:-us-east-1}
terraform init -input=false \
  -backend-config="bucket=twin-terraform-state-${AWS_ACCOUNT_ID}" \
  -backend-config="key=${ENVIRONMENT}/terraform.tfstate" \
  -backend-config="region=${AWS_REGION}" \
  -backend-config="dynamodb_table=twin-terraform-locks" \
  -backend-config="encrypt=true"

# One-time cleanup: stop managing bootstrap resources in the main stack state.
for addr in \
  aws_s3_bucket.terraform_state[0] \
  aws_s3_bucket_versioning.terraform_state[0] \
  aws_s3_bucket_server_side_encryption_configuration.terraform_state[0] \
  aws_s3_bucket_public_access_block.terraform_state[0] \
  aws_dynamodb_table.terraform_locks[0] \
  aws_iam_openid_connect_provider.github[0] \
  aws_iam_role.github_actions[0] \
  aws_iam_role_policy.github_additional[0] \
  aws_iam_role_policy_attachment.github_lambda[0] \
  aws_iam_role_policy_attachment.github_s3[0] \
  aws_iam_role_policy_attachment.github_apigateway[0] \
  aws_iam_role_policy_attachment.github_cloudfront[0] \
  aws_iam_role_policy_attachment.github_iam_read[0] \
  aws_iam_role_policy_attachment.github_bedrock[0] \
  aws_iam_role_policy_attachment.github_dynamodb[0] \
  aws_iam_role_policy_attachment.github_acm[0] \
  aws_iam_role_policy_attachment.github_route53[0]
do
  terraform state rm "$addr" >/dev/null 2>&1 || true
done

# Use prod.tfvars for production environment
TF_COMMON_VARS=(
  -var="project_name=$PROJECT_NAME"
  -var="environment=$ENVIRONMENT"
  -var="openai_api_key_secret_arn=$TF_VAR_openai_api_key_secret_arn"
  -var="openai_model_id=$TF_VAR_openai_model_id"
)

if [ "$ENVIRONMENT" = "prod" ]; then
  TF_APPLY_CMD=(terraform apply -var-file=prod.tfvars "${TF_COMMON_VARS[@]}" -auto-approve)
else
  TF_APPLY_CMD=(terraform apply "${TF_COMMON_VARS[@]}" -auto-approve)
fi

echo "🎯 Applying Terraform..."
"${TF_APPLY_CMD[@]}"

API_URL=$(terraform output -raw api_gateway_url)
FRONTEND_BUCKET=$(terraform output -raw s3_frontend_bucket)
FRONTEND_WEBSITE_URL=$(terraform output -raw frontend_website_url)
CUSTOM_URL=$(terraform output -raw custom_domain_url 2>/dev/null || true)
CLOUDFRONT_URL=$(terraform output -raw cloudfront_url 2>/dev/null || true)

# 3. Build + deploy frontend
cd ../frontend

# Create deployment environment file with API URL
echo "📝 Setting API URL for deployment..."
echo "NEXT_PUBLIC_API_URL=$API_URL" > .env.production

# Ensure deterministic install and clear stale build artifacts.
rm -rf .next out
npm ci --no-audit --no-fund
npm run build
aws s3 sync ./out "s3://$FRONTEND_BUCKET/" --delete
cd ..

# 4. Final messages
echo -e "\n✅ Deployment complete!"
# echo "🌐 CloudFront URL : $(terraform -chdir=terraform output -raw cloudfront_url)"
if [ -n "$CLOUDFRONT_URL" ]; then
  echo "🌐 CloudFront URL : $CLOUDFRONT_URL"
else
  echo "🌐 Frontend URL   : $FRONTEND_WEBSITE_URL"
fi
if [ -n "$CUSTOM_URL" ]; then
  echo "🔗 Custom domain  : $CUSTOM_URL"
fi
echo "📡 API Gateway    : $API_URL"