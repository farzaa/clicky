from collections.abc import AsyncIterator

from fastapi import APIRouter, Request, Response, status
from fastapi.responses import JSONResponse, StreamingResponse

from app.config import get_settings

router = APIRouter()


def _proxy_error_response(upstream_body: bytes, upstream_status_code: int) -> Response:
    content_type = "application/json"
    return Response(
        content=upstream_body,
        status_code=upstream_status_code,
        media_type=content_type,
    )


@router.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok"}


@router.post("/chat")
async def proxy_chat(request: Request) -> StreamingResponse | Response:
    settings = get_settings()
    request_body = await request.body()
    http_client = request.app.state.http_client

    upstream_request = http_client.build_request(
        "POST",
        "https://api.anthropic.com/v1/messages",
        content=request_body,
        headers={
            "x-api-key": settings.anthropic_api_key,
            "anthropic-version": "2023-06-01",
            "content-type": "application/json",
        },
    )
    upstream_response = await http_client.send(upstream_request, stream=True)

    if upstream_response.status_code < 200 or upstream_response.status_code >= 300:
        error_body = await upstream_response.aread()
        await upstream_response.aclose()
        return _proxy_error_response(
            upstream_body=error_body,
            upstream_status_code=upstream_response.status_code,
        )

    async def stream_upstream_bytes() -> AsyncIterator[bytes]:
        try:
            async for chunk in upstream_response.aiter_bytes():
                if chunk:
                    yield chunk
        finally:
            await upstream_response.aclose()

    return StreamingResponse(
        stream_upstream_bytes(),
        media_type=upstream_response.headers.get("content-type", "text/event-stream"),
        headers={"cache-control": "no-cache"},
    )


@router.post("/tts")
async def proxy_tts(request: Request) -> Response:
    settings = get_settings()
    request_body = await request.body()
    http_client = request.app.state.http_client

    upstream_response = await http_client.post(
        f"https://api.elevenlabs.io/v1/text-to-speech/{settings.elevenlabs_voice_id}",
        content=request_body,
        headers={
            "xi-api-key": settings.elevenlabs_api_key,
            "content-type": "application/json",
            "accept": "audio/mpeg",
        },
    )

    if upstream_response.status_code < 200 or upstream_response.status_code >= 300:
        return _proxy_error_response(
            upstream_body=upstream_response.content,
            upstream_status_code=upstream_response.status_code,
        )

    return Response(
        content=upstream_response.content,
        status_code=upstream_response.status_code,
        media_type=upstream_response.headers.get("content-type", "audio/mpeg"),
    )


@router.post("/transcribe-token")
async def create_transcribe_token(request: Request) -> JSONResponse | Response:
    settings = get_settings()
    http_client = request.app.state.http_client

    upstream_response = await http_client.get(
        "https://streaming.assemblyai.com/v3/token",
        params={"expires_in_seconds": 480},
        headers={"authorization": settings.assemblyai_api_key},
    )

    if upstream_response.status_code < 200 or upstream_response.status_code >= 300:
        return _proxy_error_response(
            upstream_body=upstream_response.content,
            upstream_status_code=upstream_response.status_code,
        )

    return JSONResponse(
        content=upstream_response.json(),
        status_code=status.HTTP_200_OK,
    )
