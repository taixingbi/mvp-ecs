#!/usr/bin/env bash
set -euo pipefail

MODEL_S3_URI="${MODEL_S3_URI:-s3://bedrock-models-646821141010/qwen/Qwen2.5-7B-Instruct/}"
MODEL_PATH="${MODEL_PATH:-/models/Qwen2.5-7B-Instruct}"
MODEL_ID="${MODEL_ID:-Qwen2.5-7B-Instruct}"
VLLM_HOST="${VLLM_HOST:-127.0.0.1}"
VLLM_PORT="${VLLM_PORT:-8000}"
ADAPTER_PORT="${ADAPTER_PORT:-8080}"
AWS_REGION="${AWS_REGION:-us-east-1}"
GPU_MEMORY_UTILIZATION="${GPU_MEMORY_UTILIZATION:-0.90}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-4096}"

export AWS_DEFAULT_REGION="${AWS_REGION}"

echo "Syncing model from ${MODEL_S3_URI} -> ${MODEL_PATH}"
mkdir -p "${MODEL_PATH}"
aws s3 sync "${MODEL_S3_URI}" "${MODEL_PATH}" --only-show-errors

if [[ ! -f "${MODEL_PATH}/config.json" ]]; then
  echo "ERROR: config.json missing after S3 sync. Check MODEL_S3_URI=${MODEL_S3_URI}" >&2
  exit 1
fi

echo "Starting vLLM on ${VLLM_HOST}:${VLLM_PORT}"
python3 -m vllm.entrypoints.openai.api_server \
  --model "${MODEL_PATH}" \
  --served-model-name "${MODEL_ID}" \
  --host "${VLLM_HOST}" \
  --port "${VLLM_PORT}" \
  --dtype auto \
  --gpu-memory-utilization "${GPU_MEMORY_UTILIZATION}" \
  --max-model-len "${MAX_MODEL_LEN}" \
  --trust-remote-code &
VLLM_PID=$!

echo "Waiting for vLLM to become healthy..."
for _ in $(seq 1 180); do
  if curl -sf "http://${VLLM_HOST}:${VLLM_PORT}/health" >/dev/null; then
    echo "vLLM is ready"
    break
  fi
  if ! kill -0 "${VLLM_PID}" 2>/dev/null; then
    echo "ERROR: vLLM exited before becoming healthy" >&2
    wait "${VLLM_PID}" || true
    exit 1
  fi
  sleep 5
done

if ! curl -sf "http://${VLLM_HOST}:${VLLM_PORT}/health" >/dev/null; then
  echo "ERROR: timed out waiting for vLLM" >&2
  kill "${VLLM_PID}" 2>/dev/null || true
  exit 1
fi

cleanup() {
  kill "${VLLM_PID}" 2>/dev/null || true
  wait "${VLLM_PID}" 2>/dev/null || true
}
trap cleanup EXIT

echo "Starting adapter on 0.0.0.0:${ADAPTER_PORT}"
export VLLM_BASE_URL="http://${VLLM_HOST}:${VLLM_PORT}"
exec python3 -m uvicorn app.main:app --host 0.0.0.0 --port "${ADAPTER_PORT}"
