# Clicky FastAPI Backend

This service replaces the thin Cloudflare Worker proxy with a hosted FastAPI backend.

## What it does today

- `POST /chat` proxies streaming Claude requests to Anthropic
- `POST /tts` proxies TTS requests to ElevenLabs
- `POST /transcribe-token` mints a short-lived AssemblyAI streaming token
- `GET /parse/` exposes a placeholder parsing module entrypoint
- `POST /parse/` is a reserved PDF-to-markdown placeholder endpoint for the future ingestion pipeline
- `GET /health` returns a basic health response

The route contract matches the existing Swift app so you can swap the backend without changing the request payload shapes.

## Local development

```bash
cd backend
python3 -m venv .venv
source .venv/bin/activate
pip install -e .
cp .env.example .env
uvicorn app.main:app --reload
```

The API will start on `http://127.0.0.1:8000`.

Then set `ClickyBackendBaseURL` in `leanring-buddy/Info.plist` to the local or hosted FastAPI base URL.

## Next backend steps

- Add user authentication and session verification
- Add Postgres for users, courses, and syllabus storage
- Implement the parsing flow in `app/parsing/service.py`
- Add PDF ingestion and markdown/chunk persistence
- Inject user/course context into `/chat` before forwarding to the model
