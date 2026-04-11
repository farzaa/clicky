# Deb FastAPI Backend

This service replaces the thin Cloudflare Worker proxy with a hosted FastAPI backend.

## What it does today

- `POST /chat` proxies streaming Claude requests to Anthropic
- `POST /tts` proxies TTS requests to ElevenLabs
- `POST /transcriptions` proxies Whisper transcription uploads to OpenAI
- `POST /auth/register` creates a user, creates a default workspace with a root folder, and returns a bearer session token
- `POST /auth/login` returns a bearer session token for an existing user
- `GET /auth/me` resolves the current bearer token to a user
- `POST /auth/logout` clears the current user's backend sessions
- `POST /workspaces/` creates a workspace with a root directory entry
- `GET /workspaces/` lists the current user's workspaces
- `POST /workspaces/{workspaceId}/entries/upload` uploads a file into `workspace_entries` and auto-creates missing parent directories
- `GET /workspaces/{workspaceId}/entries?parent_entry_path=...` lists direct children for a workspace directory path
- `GET /workspaces/{workspaceId}/entries/read?entry_path=...` reads a stored workspace file and returns text or base64 binary content
- `POST /workspaces/{workspaceId}/launch` marks a workspace as running
- `GET /agent/tools` lists backend-implemented workspace tools
- `POST /agent/runs` executes the backend agent loop against OpenAI Responses or OpenRouter Chat Completions
- `POST /agent/runs/{runId}/abort` requests cancellation of an in-flight agent run
- `GET /parse/` exposes a placeholder parsing module entrypoint
- `POST /parse/` is a reserved PDF-to-markdown placeholder endpoint for the future ingestion pipeline
- `GET /` provides a small server-rendered project website with sign-in and registration
- `GET /web/login` and `POST /web/login` provide web login compatibility routes
- `POST /web/register` creates a user + default workspace from the web UI
- `POST /web/workspaces` creates another workspace from the web UI
- `GET /web/app` shows all user workspaces, selected workspace VFS entries, and `courses`, `learner_topic_masteries`, and `learner_observations`
- `POST /web/upload` uploads a file into the selected workspace from the web UI
- `GET /health` returns a basic health response
- Connects to Postgres on startup and can optionally auto-create schema for local prototyping (`DEB_AUTO_CREATE_DATABASE_SCHEMA=true`)
- Uses Alembic migrations for explicit schema versioning (`alembic upgrade head`)

The route contract matches the existing Swift app so you can swap the backend without changing the request payload shapes.

## Current schema

The backend schema (managed by Alembic) includes:

- `users`
- `auth_sessions`
- `agents`
- `agent_sessions`
- `agent_session_messages`
- `courses`
- `learner_topic_masteries`
- `learner_observations`
- `workspaces`
- `workspace_memberships`
- `workspace_entries`
- `workspace_ingestion_jobs`

`agents` stores workspace-scoped saved agent definitions, including a persisted `system_prompt` alongside optional provider, model, description, and arbitrary metadata.

`agent_sessions` stores workspace-scoped conversation/session rows for future persisted chat history and session switching.

`workspace_entries` is the current virtual filesystem table. It supports both directories and files, and it can hold:

- markdown or text content in `text_content`
- raw binary data in `binary_content`
- MIME type, content hash, size, and metadata
- a future `storage_object_key` if you later move large files out of Postgres into object storage

## Registration and workspace bootstrapping

When a new user registers, the backend now creates a default workspace automatically and seeds it with a root `/` directory entry in `workspace_entries`.

The `launch` endpoint still exists, but it is backend-only state. It does not start a local agent or mount a user folder on the Mac.

## Agent loop

The backend now includes a standalone `app/agent/` package with:

- default saved agent settings in `app/agent/defaults.py`
- provider adapters for `openai_responses` and `openrouter_chat_completions`
- an iterative loop that feeds tool results back into the model
- in-memory run abortion by `run_id`
- backend-owned tools in `companion.point`, `workspace.list_entries`, `workspace.read_entry`, `workspace.write_entry`, and `workspace.run_bash`
- a default OpenAI Responses model of `gpt-5.4-mini` when `/agent/runs` omits `model`

`workspace.run_bash` now uses a custom `just-bash` filesystem backed by serialized `workspace_entries` data rather than a temp directory on disk. The Python backend loads the workspace from Postgres, the Node runner executes the shell against that virtual filesystem, and the final filesystem snapshot is persisted back into `workspace_entries` after the command finishes.

Each new workspace also gets a default saved `agents` row for Deb with a short system prompt, default provider `openai_responses`, and default model `gpt-5.4-mini`.

`/agent/runs` now accepts multimodal screenshot input in user messages via `messages[].images[]` (`image_base64`, `mime_type`, `label`, `pixel_width`, `pixel_height`, `is_primary_focus`).

Current limitation:

- aborting is process-local in memory, so it works only within the same FastAPI process
- the loop is not wired into the Swift app yet
- there is no streaming agent response surface yet

## Local development

```bash
cd backend
docker compose up -d postgres

python3 -m venv .venv
source .venv/bin/activate
pip install -e .
cd app/agent
npm install
cd ../..
cp .env.example .env
alembic upgrade head
uvicorn app.main:app --reload
```

The API will start on `http://127.0.0.1:8000`.

Then set `DebBackendBaseURL` in `leanring-buddy/Info.plist` to the local or hosted FastAPI base URL.

If you already started an older local Postgres volume before the auth/workspace schema existed, reset it before booting this version:

```bash
docker compose down -v
docker compose up -d postgres
```

If your local database already has tables created by the old `create_all` path and no Alembic history row yet, run this one-time baseline command:

```bash
alembic stamp head
```

## Next backend steps

- Add user authentication and session verification
- Add course tables and document ownership tables on top of `workspaces`
- Implement the parsing flow in `app/parsing/service.py`
- Add PDF ingestion and markdown/chunk persistence
- Inject user/course context into `/chat` before forwarding to the model
