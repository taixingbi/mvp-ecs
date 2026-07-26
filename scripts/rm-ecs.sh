#!/usr/bin/env bash
# Tear down the ECS inference MVP (CloudFormation stack + optional ECR repo).
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
STACK_NAME="${STACK_NAME:-ecs-inference-mvp}"
ECR_REPO="${ECR_REPO:-mvp-ecs-qwen}"
DELETE_ECR="${DELETE_ECR:-1}"

echo "Deleting CloudFormation stack ${STACK_NAME} in ${AWS_REGION}"
if aws cloudformation describe-stacks --stack-name "${STACK_NAME}" --region "${AWS_REGION}" >/dev/null 2>&1; then
  aws cloudformation delete-stack --stack-name "${STACK_NAME}" --region "${AWS_REGION}"
  echo "Waiting for stack delete to complete..."
  aws cloudformation wait stack-delete-complete --stack-name "${STACK_NAME}" --region "${AWS_REGION}"
  echo "Stack ${STACK_NAME} deleted."
else
  echo "Stack ${STACK_NAME} not found; skipping."
fi

if [[ "${DELETE_ECR}" == "1" ]]; then
  if aws ecr describe-repositories --repository-names "${ECR_REPO}" --region "${AWS_REGION}" >/dev/null 2>&1; then
    echo "Deleting ECR repository ${ECR_REPO} (including images)"
    aws ecr delete-repository \
      --repository-name "${ECR_REPO}" \
      --region "${AWS_REGION}" \
      --force >/dev/null
    echo "ECR repository ${ECR_REPO} deleted."
  else
    echo "ECR repository ${ECR_REPO} not found; skipping."
  fi
else
  echo "DELETE_ECR=${DELETE_ECR}; leaving ECR repository ${ECR_REPO} in place."
fi

echo "Done."
