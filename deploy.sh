#!/bin/bash
set -euo pipefail

STACK_NAME="app-hackatho-rise94f7a1bc-stack"
ARTIFACTS_BUCKET="app-hackatho-rise94f7a1bctest-artifacts"
REGION="ap-southeast-1"

echo "==> [1/8] Ensuring artifacts S3 bucket exists..."
aws s3api head-bucket --bucket "$ARTIFACTS_BUCKET" --region "$REGION" 2>/dev/null || \
  aws s3api create-bucket \
    --bucket "$ARTIFACTS_BUCKET" \
    --region "$REGION" \
    --create-bucket-configuration LocationConstraint="$REGION"

echo "==> [2/8] Installing backend dependencies..."
cd backend
npm install
npm ci
cd ..

echo "==> [3/8] Installing frontend dependencies and building..."
cd frontend
npm install
npm ci
npm run build
cd ..

echo "==> [4/8] Building SAM application..."
sam build --template-file template.yaml

echo "==> [5/8] Deploying SAM stack..."
sam deploy \
  --stack-name "$STACK_NAME" \
  --s3-bucket "$ARTIFACTS_BUCKET" \
  --region "$REGION" \
  --capabilities CAPABILITY_NAMED_IAM \
  --no-fail-on-empty-changeset \
  --no-confirm-changeset

echo "==> [6/8] Retrieving stack outputs..."
API_URL=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --region "$REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`ApiUrl`].OutputValue' \
  --output text)

FRONTEND_URL=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --region "$REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`FrontendUrl`].OutputValue' \
  --output text)

DIST_ID=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --region "$REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`DistributionId`].OutputValue' \
  --output text)

FRONTEND_BUCKET=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --region "$REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`FrontendBucketName`].OutputValue' \
  --output text)

echo "  API URL: $API_URL"
echo "  Frontend URL: $FRONTEND_URL"
echo "  Distribution ID: $DIST_ID"
echo "  Frontend Bucket: $FRONTEND_BUCKET"

echo "==> [7/8] Uploading frontend to S3..."
# Inject the API URL into the frontend config
echo "window.__API_URL__='${API_URL}';" > frontend/dist/config.js

aws s3 sync frontend/dist/ "s3://${FRONTEND_BUCKET}/" \
  --delete \
  --region "$REGION"

# Invalidate CloudFront cache
if [ -n "$DIST_ID" ]; then
  aws cloudfront create-invalidation \
    --distribution-id "$DIST_ID" \
    --paths "/*" \
    --region "$REGION" \
    --output text \
    --query 'Invalidation.Id' || true
fi

echo "==> [8/8] Writing outputs.json..."
cat > outputs.json <<EOF
{
  "app_url": "${FRONTEND_URL}",
  "api_url": "${API_URL}"
}
EOF

echo ""
echo "✅ Deployment complete!"
echo "   App URL: ${FRONTEND_URL}"
echo "   API URL: ${API_URL}"
