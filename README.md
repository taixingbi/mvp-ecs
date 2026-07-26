# mvp-ecs

Self-hosted **Qwen2.5-7B-Instruct** on ECS GPU (`g5.xlarge` / A10G), with the same HTTP API as [mvp-bedrock](https://github.com/taixingbi/mvp-bedrock) for capacity/cost comparison.

## Stack

| Piece | Value |
| --- | --- |
| Model weights | `s3://bedrock-models-646821141010/qwen/Qwen2.5-7B-Instruct/` |
| Compute | 1 × `g5.xlarge` (1 × A10G) |
| Serving | vLLM + FastAPI adapter |
| Region | `us-east-1` |
| CloudFormation stack | `ecs-inference-mvp` |

## GitHub secrets

Repository secrets (Settings → Secrets and variables → Actions):

| Name | Purpose |
| --- | --- |
| `AWS_ACCESS_KEY_ID` | Deploy credentials |
| `AWS_SECRET_ACCESS_KEY` | Deploy credentials |
| `INFERENCE_API_KEY` | Value required in `Authorization: Bearer` or `x-api-key` |

Optional variable: `AWS_REGION` (default `us-east-1`).

Set from a machine that already has AWS + `gh` auth:

```bash
./scripts/set-github-secrets.sh
# or manually:
gh secret set AWS_ACCESS_KEY_ID --body "$AWS_ACCESS_KEY_ID" --repo taixingbi/mvp-ecs
gh secret set AWS_SECRET_ACCESS_KEY --body "$AWS_SECRET_ACCESS_KEY" --repo taixingbi/mvp-ecs
gh secret set INFERENCE_API_KEY --body "$INFERENCE_API_KEY" --repo taixingbi/mvp-ecs
```

## Deploy

Push to `main` or run the **Deploy** workflow. Locally (Docker + AWS CLI required):

```bash
export API_KEY='your-shared-secret'
./scripts/deploy.sh
```

After deploy:

```bash
export SERVICE_URL=$(aws cloudformation describe-stacks \
  --region us-east-1 \
  --stack-name ecs-inference-mvp \
  --query "Stacks[0].Outputs[?OutputKey=='ServiceUrl'].OutputValue" \
  --output text)
export INFERENCE_API_KEY='your-shared-secret'

curl -sS -X POST "${SERVICE_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${INFERENCE_API_KEY}" \
  -d '{
    "model": "Qwen/Qwen2.5-7B-Instruct",
    "messages": [{"role": "user", "content": "Hello"}],
    "max_tokens": 64,
    "temperature": 0,
    "top_p": 1.0
  }'
```

Cold start includes S3 sync + model load; allow several minutes before `/health` returns `{"status":"ok"}`.

## API

### OpenAI-compatible (preferred)

`POST` `/v1/chat/completions`

```json
{
  "model": "Qwen/Qwen2.5-7B-Instruct",
  "messages": [
    {"role": "system", "content": "optional system prompt"},
    {"role": "user", "content": "Hello"}
  ],
  "max_tokens": 512,
  "temperature": 0,
  "top_p": 1.0
}
```

Headers (either works):

- `Authorization: Bearer <INFERENCE_API_KEY>`
- `x-api-key: <INFERENCE_API_KEY>`

Success: OpenAI `chat.completion` shape (`choices`, `usage.prompt_tokens`, etc.). The adapter proxies vLLM; request `model` is echoed when provided.

### Legacy

`POST` `/` or `/infer` still accepts `{"prompt","system","max_tokens"}` and returns `{"text","model","usage":{"input_tokens","output_tokens"}}`.

## Cost

A single on-demand `g5.xlarge` is roughly $1+/hour. Tear down when idle:

```bash
./scripts/rm-ecs.sh
# keep ECR images: 
DELETE_ECR=0 ./scripts/rm-ecs.sh
```
