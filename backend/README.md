# Clicky FastAPI Backend

This service replaces the thin Cloudflare Worker proxy with a hosted FastAPI backend.

## What it does today

- `POST /chat` proxies streaming Claude requests to Anthropic
- `POST /tts` proxies TTS requests to ElevenLabs
- `POST /transcribe-token` mints a short-lived AssemblyAI streaming token
- `POST /auth/register` creates a user, creates a default workspace with a root folder, and returns a bearer session token
- `POST /auth/login` returns a bearer session token for an existing user
- `GET /auth/me` resolves the current bearer token to a user
- `POST /auth/logout` clears the current user's backend sessions
- `POST /workspaces/` creates a workspace with a root directory entry
- `GET /workspaces/` lists the current user's workspaces
- `POST /workspaces/{workspaceId}/launch` marks a workspace as running
- `GET /parse/` exposes a placeholder parsing module entrypoint
- `POST /parse/` is a reserved PDF-to-markdown placeholder endpoint for the future ingestion pipeline
- `GET /health` returns a basic health response
- Connects to Postgres on startup and auto-creates the current schema

The route contract matches the existing Swift app so you can swap the backend without changing the request payload shapes.

## Current schema

The backend now bootstraps these Postgres tables:

- `users`
- `auth_sessions`
- `workspaces`
- `workspace_memberships`
- `workspace_entries`

`workspace_entries` is the current virtual filesystem table. It supports both directories and files, and it can hold:

- markdown or text content in `text_content`
- raw binary data in `binary_content`
- MIME type, content hash, size, and metadata
- a future `storage_object_key` if you later move large files out of Postgres into object storage

## Registration and workspace bootstrapping

When a new user registers, the backend now creates a default workspace automatically and seeds it with a root `/` directory entry in `workspace_entries`.

The `launch` endpoint still exists, but it is backend-only state. It does not start a local agent or mount a user folder on the Mac.

## Local development

```bash
cd backend
docker compose up -d postgres

python3 -m venv .venv
source .venv/bin/activate
pip install -e .
cp .env.example .env
uvicorn app.main:app --reload
```

The API will start on `http://127.0.0.1:8000`.

Then set `ClickyBackendBaseURL` in `leanring-buddy/Info.plist` to the local or hosted FastAPI base URL.

If you already started an older local Postgres volume before the auth/workspace schema existed, reset it before booting this version:

```bash
docker compose down -v
docker compose up -d postgres
```

## Next backend steps

- Add user authentication and session verification
- Add course tables and document ownership tables on top of `workspaces`
- Implement the parsing flow in `app/parsing/service.py`
- Add PDF ingestion and markdown/chunk persistence
- Inject user/course context into `/chat` before forwarding to the model
