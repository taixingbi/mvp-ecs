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
    "Access-Control-Allow-Headers": "content-type,x-api-key",
    "Access-Control-Allow-Methods": "POST,OPTIONS",
}

app = FastAPI(title="mvp-ecs")


def _json(status: int, body: dict[str, Any]) -> JSONResponse:
    return JSONResponse(status_code=status, content=body, headers=CORS_HEADERS)


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
async def options() -> Response:
    return Response(status_code=204, headers=CORS_HEADERS)


async def _infer(request: Request) -> JSONResponse:
    provided = request.headers.get("x-api-key", "")
    if not API_KEY or provided != API_KEY:
        return _json(401, {"error": "unauthorized"})

    try:
        payload = await request.json()
    except Exception:  # noqa: BLE001
        return _json(400, {"error": "invalid JSON body"})

    prompt = payload.get("prompt")
    if not isinstance(prompt, str) or not prompt.strip():
        return _json(400, {"error": "prompt is required"})

    system = payload.get("system")
    max_tokens = payload.get("max_tokens", 512)
    if not isinstance(max_tokens, int) or max_tokens < 1 or max_tokens > 4096:
        return _json(400, {"error": "max_tokens must be an integer between 1 and 4096"})

    messages: list[dict[str, str]] = []
    if isinstance(system, str) and system.strip():
        messages.append({"role": "system", "content": system})
    messages.append({"role": "user", "content": prompt})

    try:
        async with httpx.AsyncClient(timeout=300.0) as client:
            resp = await client.post(
                f"{VLLM_BASE_URL}/v1/chat/completions",
                json={
                    "model": MODEL_ID,
                    "messages": messages,
                    "max_tokens": max_tokens,
                },
            )
            resp.raise_for_status()
            data = resp.json()
    except httpx.HTTPStatusError as exc:
        detail = exc.response.text[:500]
        return _json(502, {"error": "vllm request failed", "detail": detail})
    except Exception as exc:  # noqa: BLE001
        return _json(502, {"error": "vllm request failed", "detail": str(exc)})

    choice = (data.get("choices") or [{}])[0]
    message = choice.get("message") or {}
    text = message.get("content") or ""
    usage = data.get("usage") or {}

    return _json(
        200,
        {
            "text": text,
            "model": MODEL_ID,
            "usage": {
                "input_tokens": usage.get("prompt_tokens", 0),
                "output_tokens": usage.get("completion_tokens", 0),
            },
        },
    )


@app.post("/")
@app.post("/infer")
async def infer(request: Request) -> JSONResponse:
    return await _infer(request)


@app.api_route("/{full_path:path}", methods=["GET", "POST", "PUT", "PATCH", "DELETE"])
async def not_found(full_path: str) -> JSONResponse:
    return _json(404, {"error": "not found"})
