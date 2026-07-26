#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

AWS_REGION="${AWS_REGION:-us-east-1}"
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"
ECR_REPO="${ECR_REPO:-mvp-ecs-qwen}"
STACK_NAME="${STACK_NAME:-ecs-inference-mvp}"
IMAGE_TAG="${IMAGE_TAG:-$(git rev-parse --short HEAD 2>/dev/null || echo latest)}"
API_KEY="${API_KEY:-${INFERENCE_API_KEY:-}}"
MODEL_S3_URI="${MODEL_S3_URI:-s3://bedrock-models-646821141010/qwen/Qwen2.5-7B-Instruct/}"
DESIRED_COUNT="${DESIRED_COUNT:-1}"

if [[ -z "${API_KEY}" ]]; then
  echo "ERROR: set API_KEY or INFERENCE_API_KEY" >&2
  exit 1
fi

IMAGE_URI="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO}:${IMAGE_TAG}"

echo "Ensuring ECR repository ${ECR_REPO} exists"
aws ecr describe-repositories --repository-names "${ECR_REPO}" --region "${AWS_REGION}" >/dev/null 2>&1 \
  || aws ecr create-repository --repository-name "${ECR_REPO}" --region "${AWS_REGION}" >/dev/null

echo "Logging in to ECR"
aws ecr get-login-password --region "${AWS_REGION}" \
  | docker login --username AWS --password-stdin "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

echo "Building ${IMAGE_URI}"
docker build -t "${IMAGE_URI}" .

echo "Pushing ${IMAGE_URI}"
docker push "${IMAGE_URI}"

echo "Deploying CloudFormation stack ${STACK_NAME}"
aws cloudformation deploy \
  --region "${AWS_REGION}" \
  --stack-name "${STACK_NAME}" \
  --template-file infra/ecs-stack.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
    "ApiKey=${API_KEY}" \
    "ImageUri=${IMAGE_URI}" \
    "ModelS3Uri=${MODEL_S3_URI}" \
    "DesiredCount=${DESIRED_COUNT}" \
  --no-fail-on-empty-changeset

SERVICE_URL="$(aws cloudformation describe-stacks \
  --region "${AWS_REGION}" \
  --stack-name "${STACK_NAME}" \
  --query "Stacks[0].Outputs[?OutputKey=='ServiceUrl'].OutputValue" \
  --output text)"

echo "Deployed. ServiceUrl=${SERVICE_URL}"
echo "Example:"
echo "  curl -sS -X POST \"${SERVICE_URL}/infer\" \\"
echo "    -H 'content-type: application/json' \\"
echo "    -H \"x-api-key: \${API_KEY}\" \\"
echo "    -d '{\"prompt\":\"Hello\",\"max_tokens\":64}'"
