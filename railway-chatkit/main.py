import os
import json
from datetime import datetime, timezone

import httpx
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse, StreamingResponse


app = FastAPI()

CLOUDFLARE_API_URL = os.environ.get("CLOUDFLARE_API_URL", "").rstrip("/")
WORKER_API_KEY = os.environ.get("WORKER_API_KEY", "")
DEFAULT_ACCOUNT_ID = os.environ.get("DEFAULT_ACCOUNT_ID", "skylerbaird@me.com").lower()
DEFAULT_WORKSPACE_ID = os.environ.get("DEFAULT_WORKSPACE_ID", "default")


def _extract_query(payload: dict) -> str:
    if isinstance(payload.get("query"), str) and payload["query"].strip():
        return payload["query"].strip()

    input_obj = payload.get("input")
    if isinstance(input_obj, dict):
        content = input_obj.get("content")
        if isinstance(content, list):
            parts = []
            for block in content:
                if isinstance(block, dict) and isinstance(block.get("text"), str):
                    parts.append(block["text"])
            q = " ".join(parts).strip()
            if q:
                return q

    return ""


def _extract_thread_id(payload: dict) -> str | None:
    if isinstance(payload.get("threadId"), str) and payload["threadId"].strip():
        return payload["threadId"].strip()
    thread = payload.get("thread")
    if isinstance(thread, dict) and isinstance(thread.get("id"), str) and thread["id"].strip():
        return thread["id"].strip()
    return None


@app.get("/health")
async def health() -> dict:
    return {"status": "healthy"}


@app.post("/chatkit")
async def chatkit_endpoint(request: Request):
    if not CLOUDFLARE_API_URL or not WORKER_API_KEY:
        raise HTTPException(status_code=500, detail="Missing CLOUDFLARE_API_URL or WORKER_API_KEY")

    payload = await request.json()
    if not isinstance(payload, dict):
        raise HTTPException(status_code=400, detail="Invalid JSON payload")

    query = _extract_query(payload)
    if not query:
        raise HTTPException(status_code=400, detail="Missing query")

    thread_id = _extract_thread_id(payload)
    session_id = payload.get("sessionId") if isinstance(payload.get("sessionId"), str) else None
    if not session_id:
        session_id = thread_id or f"railway-{int(datetime.now(timezone.utc).timestamp())}"

    cf_body = {
        "workspaceId": DEFAULT_WORKSPACE_ID,
        "accountId": (payload.get("accountId") or DEFAULT_ACCOUNT_ID),
        "sessionId": session_id,
        "threadId": thread_id,
        "query": query,
        "userId": payload.get("userId") if isinstance(payload.get("userId"), str) else "railway-user"
    }

    async with httpx.AsyncClient(timeout=45) as client:
        try:
            resp = await client.post(
                f"{CLOUDFLARE_API_URL}/chat/query",
                headers={
                    "Authorization": f"Bearer {WORKER_API_KEY}",
                    "Content-Type": "application/json"
                },
                json=cf_body
            )
            resp.raise_for_status()
            data = resp.json()
        except httpx.HTTPStatusError as exc:
            detail = exc.response.text[:1000]
            raise HTTPException(status_code=502, detail=f"Backend status error: {detail}") from exc
        except Exception as exc:
            raise HTTPException(status_code=502, detail=f"Backend request failed: {str(exc)}") from exc

    accepts_sse = "text/event-stream" in (request.headers.get("accept") or "")
    if accepts_sse:
        async def event_stream():
            progress = {"type": "progress", "text": "Searching your emails..."}
            yield f"event: progress\ndata: {json.dumps(progress)}\n\n"

            msg = {
                "type": "message",
                "answer": data.get("answer", "No response generated."),
                "citations": data.get("citations", []),
                "proposals": data.get("proposals", []),
                "threadId": data.get("sessionId") or session_id,
                "runId": data.get("runId")
            }
            yield f"event: message\ndata: {json.dumps(msg)}\n\n"
            yield "event: done\ndata: {}\n\n"

        return StreamingResponse(event_stream(), media_type="text/event-stream")

    return JSONResponse(
        {
            "ok": True,
            "answer": data.get("answer", "No response generated."),
            "citations": data.get("citations", []),
            "proposals": data.get("proposals", []),
            "threadId": data.get("sessionId") or session_id,
            "runId": data.get("runId")
        }
    )
