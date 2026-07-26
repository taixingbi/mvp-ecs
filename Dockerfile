FROM vllm/vllm-openai:v0.8.5

USER root

RUN apt-get update && apt-get install -y --no-install-recommends \
      curl \
      unzip \
      ca-certificates \
    && curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip \
    && unzip -q /tmp/awscliv2.zip -d /tmp \
    && /tmp/aws/install \
    && rm -rf /tmp/aws /tmp/awscliv2.zip /var/lib/apt/lists/*

WORKDIR /workspace

COPY app/requirements.txt /workspace/app/requirements.txt
RUN pip install --no-cache-dir -r /workspace/app/requirements.txt

COPY app /workspace/app
COPY scripts/entrypoint.sh /workspace/scripts/entrypoint.sh
RUN chmod +x /workspace/scripts/entrypoint.sh

ENV MODEL_S3_URI=s3://bedrock-models-646821141010/qwen/Qwen2.5-7B-Instruct/ \
    MODEL_PATH=/models/Qwen2.5-7B-Instruct \
    MODEL_ID=Qwen2.5-7B-Instruct \
    ADAPTER_PORT=8080 \
    VLLM_PORT=8000 \
    AWS_REGION=us-east-1

EXPOSE 8080

ENTRYPOINT ["/workspace/scripts/entrypoint.sh"]
