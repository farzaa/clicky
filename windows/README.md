# Clicky Windows Port

This folder contains a Python-based Windows wrapper for Clicky.

## Prerequisites

- Windows 10/11
- Python 3.11+
- A running Deb backend (`backend/app/main.py`) reachable from Windows

## Setup

From the repository root:

```powershell
python -m venv windows\.venv
windows\.venv\Scripts\python -m pip install --upgrade pip
windows\.venv\Scripts\python -m pip install -r windows\requirements.txt
```

Create `windows\.env` from the example:

```powershell
Copy-Item windows\.env.example windows\.env
```

Then edit `windows\.env`:

```env
DEB_BACKEND_BASE_URL=http://127.0.0.1:8000
DEB_PARSE_SOURCE_DOCUMENT_PATH=C:\path\to\course.pdf
# or
DEB_PARSE_SOURCE_DOCUMENT_URL=https://example.com/course.pdf
# optional
DEB_PARSE_OUTPUT_ROOT_DIRECTORY=C:\path\to\output
```

## Run

```powershell
windows\.venv\Scripts\python windows\main.py
```

The app opens a small always-on-top window with:

- `Listen`: start/stop recording or interrupt with a new instruction
- `Stop`: stop the current run

### Using `/parse`

To trigger backend parsing, start your spoken request with `parse` or `/parse`.

Examples:

- `parse chapter 3 derivatives`
- `/parse limits and continuity`

## Notes

- The app sends requests to your backend endpoints: `/chat`, `/tts`, and `/parse`.
- API keys live in `backend/.env`, not in the Windows frontend.
- The app loads environment variables from `windows\.env` first, then falls back to a repo-root `.env` if present.
- No external media player (like `ffplay`) is required.
