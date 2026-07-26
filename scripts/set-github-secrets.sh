#!/usr/bin/env bash
# Set GitHub Actions repository secrets for mvp-ecs.
# Does not print secret values.
set -euo pipefail

REPO="${REPO:-taixingbi/mvp-ecs}"

if [[ -z "${AWS_ACCESS_KEY_ID:-}" || -z "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
  AWS_ACCESS_KEY_ID="$(aws configure get aws_access_key_id)"
  AWS_SECRET_ACCESS_KEY="$(aws configure get aws_secret_access_key)"
fi

if [[ -z "${AWS_ACCESS_KEY_ID:-}" || -z "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
  echo "ERROR: could not resolve AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY" >&2
  exit 1
fi

if [[ -z "${INFERENCE_API_KEY:-}" ]]; then
  INFERENCE_API_KEY="$(openssl rand -hex 16)"
  echo "Generated INFERENCE_API_KEY (save it; value is not printed again by this script)."
  # Write once to a local file the user can read, not stdout of CI logs
  umask 077
  printf '%s\n' "${INFERENCE_API_KEY}" > .inference_api_key
  echo "Wrote ./.inference_api_key (gitignored)."
fi

gh secret set AWS_ACCESS_KEY_ID --repo "${REPO}" --body "${AWS_ACCESS_KEY_ID}"
gh secret set AWS_SECRET_ACCESS_KEY --repo "${REPO}" --body "${AWS_SECRET_ACCESS_KEY}"
gh secret set INFERENCE_API_KEY --repo "${REPO}" --body "${INFERENCE_API_KEY}"

echo "Set secrets on ${REPO}:"
gh secret list --repo "${REPO}"
