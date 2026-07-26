import os
from typing import Any

import httpx
from fastapi import FastAPI, Request, Response
from fastapi.responses import JSONResponse

API_KEY = os.environ.get("API_KEY", "")
MODEL_ID = os.environ.get("MODEL_ID", "Qwen2.5-7B-Instruct")
VLLM_BASE_URL = os.environ.get("VLLM_BASE_URL", "http://127.0.0.1:8000").rstrip("/")

CORS_HEADERS = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "content-type,x-api-key,authorization",
    "Access-Control-Allow-Methods": "POST,OPTIONS",
}

app = FastAPI(title="mvp-ecs")


def _json(status: int, body: dict[str, Any]) -> JSONResponse:
    return JSONResponse(status_code=status, content=body, headers=CORS_HEADERS)


def _authorized(request: Request) -> bool:
    if not API_KEY:
        return False
    if request.headers.get("x-api-key", "") == API_KEY:
        return True
    auth = request.headers.get("authorization", "")
    if auth.lower().startswith("bearer "):
        return auth[7:].strip() == API_KEY
    return False


def _parse_sampling(payload: dict[str, Any]) -> tuple[int, float | None, float | None]:
    max_tokens = payload.get("max_tokens", 512)
    if not isinstance(max_tokens, int) or max_tokens < 1 or max_tokens > 4096:
        raise ValueError("max_tokens must be an integer between 1 and 4096")

    temperature = payload.get("temperature")
    if temperature is not None and (
        not isinstance(temperature, (int, float)) or temperature < 0 or temperature > 2
    ):
        raise ValueError("temperature must be a number between 0 and 2")

    top_p = payload.get("top_p")
    if top_p is not None and (not isinstance(top_p, (int, float)) or top_p <= 0 or top_p > 1):
        raise ValueError("top_p must be a number between 0 and 1")

    return (
        max_tokens,
        float(temperature) if temperature is not None else None,
        float(top_p) if top_p is not None else None,
    )


def _normalize_messages(payload: dict[str, Any]) -> list[dict[str, str]]:
    """Accept OpenAI messages, or legacy {prompt, system}."""
    messages = payload.get("messages")
    if isinstance(messages, list) and messages:
        normalized: list[dict[str, str]] = []
        for item in messages:
            if not isinstance(item, dict):
                raise ValueError("each message must be an object")
            role = item.get("role")
            content = item.get("content")
            if role not in ("system", "user", "assistant"):
                raise ValueError("message.role must be system, user, or assistant")
            if not isinstance(content, str):
                raise ValueError("message.content must be a string")
            normalized.append({"role": role, "content": content})
        if not any(m["role"] == "user" for m in normalized):
            raise ValueError("at least one user message is required")
        return normalized

    prompt = payload.get("prompt")
    if not isinstance(prompt, str) or not prompt.strip():
        raise ValueError("messages or prompt is required")

    normalized = []
    system = payload.get("system")
    if isinstance(system, str) and system.strip():
        normalized.append({"role": "system", "content": system})
    normalized.append({"role": "user", "content": prompt})
    return normalized


async def _vllm_chat_completion(
    messages: list[dict[str, str]],
    max_tokens: int,
    temperature: float | None,
    top_p: float | None,
) -> dict[str, Any]:
    body: dict[str, Any] = {
        "model": MODEL_ID,
        "messages": messages,
        "max_tokens": max_tokens,
    }
    if temperature is not None:
        body["temperature"] = temperature
    if top_p is not None:
        body["top_p"] = top_p

    async with httpx.AsyncClient(timeout=300.0) as client:
        resp = await client.post(f"{VLLM_BASE_URL}/v1/chat/completions", json=body)
        resp.raise_for_status()
        return resp.json()


@app.get("/health")
async def health() -> JSONResponse:
    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            resp = await client.get(f"{VLLM_BASE_URL}/health")
            if resp.status_code != 200:
                return _json(503, {"status": "starting"})
    except httpx.HTTPError:
        return _json(503, {"status": "starting"})
    return _json(200, {"status": "ok"})


@app.options("/")
@app.options("/infer")
@app.options("/v1/chat/completions")
async def options() -> Response:
    return Response(status_code=204, headers=CORS_HEADERS)


@app.post("/v1/chat/completions")
async def chat_completions(request: Request) -> JSONResponse:
    if not _authorized(request):
        return _json(401, {"error": "unauthorized"})

    try:
        payload = await request.json()
    except Exception:  # noqa: BLE001
        return _json(400, {"error": "invalid JSON body"})

    try:
        messages = _normalize_messages(payload)
        max_tokens, temperature, top_p = _parse_sampling(payload)
    except ValueError as exc:
        return _json(400, {"error": str(exc)})

    try:
        data = await _vllm_chat_completion(messages, max_tokens, temperature, top_p)
    except httpx.HTTPStatusError as exc:
        return _json(502, {"error": "vllm request failed", "detail": exc.response.text[:500]})
    except Exception as exc:  # noqa: BLE001
        return _json(502, {"error": "vllm request failed", "detail": str(exc)})

    # Echo request model if provided; otherwise keep vLLM's served name.
    request_model = payload.get("model")
    if isinstance(request_model, str) and request_model:
        data["model"] = request_model

    return _json(200, data)


@app.post("/")
@app.post("/infer")
async def infer(request: Request) -> JSONResponse:
    if not _authorized(request):
        return _json(401, {"error": "unauthorized"})

    try:
        payload = await request.json()
    except Exception:  # noqa: BLE001
        return _json(400, {"error": "invalid JSON body"})

    try:
        messages = _normalize_messages(payload)
        max_tokens, temperature, top_p = _parse_sampling(payload)
    except ValueError as exc:
        return _json(400, {"error": str(exc)})

    try:
        data = await _vllm_chat_completion(messages, max_tokens, temperature, top_p)
    except httpx.HTTPStatusError as exc:
        return _json(502, {"error": "vllm request failed", "detail": exc.response.text[:500]})
    except Exception as exc:  # noqa: BLE001
        return _json(502, {"error": "vllm request failed", "detail": str(exc)})

    choice = (data.get("choices") or [{}])[0]
    message = choice.get("message") or {}
    text = message.get("content") or ""
    usage = data.get("usage") or {}
    request_model = payload.get("model")
    response_model = (
        request_model if isinstance(request_model, str) and request_model else MODEL_ID
    )

    return _json(
        200,
        {
            "text": text,
            "model": response_model,
            "usage": {
                "input_tokens": usage.get("prompt_tokens", 0),
                "output_tokens": usage.get("completion_tokens", 0),
            },
        },
    )


@app.api_route("/{full_path:path}", methods=["GET", "POST", "PUT", "PATCH", "DELETE"])
async def not_found(full_path: str) -> JSONResponse:
    return _json(404, {"error": "not found"})
