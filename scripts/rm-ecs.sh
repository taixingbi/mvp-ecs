#!/usr/bin/env bash
# Tear down the ECS inference MVP (CloudFormation stack + optional ECR repo).
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
STACK_NAME="${STACK_NAME:-ecs-inference-mvp}"
ECR_REPO="${ECR_REPO:-mvp-ecs-qwen}"
DELETE_ECR="${DELETE_ECR:-1}"
CLUSTER_NAME="${CLUSTER_NAME:-${STACK_NAME}-cluster}"
SERVICE_NAME="${SERVICE_NAME:-${STACK_NAME}-svc}"
ASG_NAME="${ASG_NAME:-${STACK_NAME}-asg}"

echo "Pre-delete: force-stop ECS service / scale ASG (avoids CFN delete timeouts)"
if aws ecs describe-services --cluster "${CLUSTER_NAME}" --services "${SERVICE_NAME}" --region "${AWS_REGION}" \
  --query 'services[0].status' --output text 2>/dev/null | grep -vq 'None\|INACTIVE'; then
  aws ecs update-service --cluster "${CLUSTER_NAME}" --service "${SERVICE_NAME}" \
    --desired-count 0 --region "${AWS_REGION}" >/dev/null 2>&1 || true
  aws ecs delete-service --cluster "${CLUSTER_NAME}" --service "${SERVICE_NAME}" \
    --force --region "${AWS_REGION}" >/dev/null 2>&1 || true
  echo "ECS service ${SERVICE_NAME} force-delete requested."
fi

if aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "${ASG_NAME}" \
  --region "${AWS_REGION}" --query 'AutoScalingGroups[0].AutoScalingGroupName' --output text 2>/dev/null \
  | grep -q "${ASG_NAME}"; then
  aws autoscaling update-auto-scaling-group \
    --auto-scaling-group-name "${ASG_NAME}" \
    --min-size 0 --max-size 0 --desired-capacity 0 \
    --region "${AWS_REGION}" >/dev/null 2>&1 || true
  INSTANCE_IDS="$(aws ec2 describe-instances --region "${AWS_REGION}" \
    --filters "Name=tag:aws:autoscaling:groupName,Values=${ASG_NAME}" \
              "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[].InstanceId' --output text)"
  if [[ -n "${INSTANCE_IDS}" && "${INSTANCE_IDS}" != "None" ]]; then
    # shellcheck disable=SC2086
    aws ec2 terminate-instances --region "${AWS_REGION}" --instance-ids ${INSTANCE_IDS} >/dev/null || true
    echo "Terminated instances: ${INSTANCE_IDS}"
  fi
fi

echo "Deleting CloudFormation stack ${STACK_NAME} in ${AWS_REGION}"
STATUS="$(aws cloudformation describe-stacks --stack-name "${STACK_NAME}" --region "${AWS_REGION}" \
  --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "NOT_FOUND")"

if [[ "${STATUS}" == "NOT_FOUND" ]]; then
  echo "Stack ${STACK_NAME} not found; skipping."
else
  # DELETE_FAILED stacks can be retried with delete-stack
  aws cloudformation delete-stack --stack-name "${STACK_NAME}" --region "${AWS_REGION}"
  echo "Waiting for stack delete to complete..."
  if ! aws cloudformation wait stack-delete-complete --stack-name "${STACK_NAME}" --region "${AWS_REGION}"; then
    echo "ERROR: stack delete did not complete. Current status:" >&2
    aws cloudformation describe-stacks --stack-name "${STACK_NAME}" --region "${AWS_REGION}" \
      --query 'Stacks[0].{Status:StackStatus,Reason:StackStatusReason}' --output json >&2 || true
    aws cloudformation describe-stack-events --stack-name "${STACK_NAME}" --region "${AWS_REGION}" \
      --query "StackEvents[?contains(ResourceStatus,'FAILED')].[LogicalResourceId,ResourceStatusReason]" \
      --output table >&2 || true
    exit 1
  fi
  echo "Stack ${STACK_NAME} deleted."
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
