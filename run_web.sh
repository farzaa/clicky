#!/bin/bash
# Clicky Web Companion Launcher
# Boots SMRITI Memory Core, Starts Web Companion Server, and opens browser

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$DIR"

echo "⚡ Starting Clicky Web Companion with SMRITI Memory..."

# 1. Check or start SMRITI local daemon
SMRITI_HEALTH=$(curl -s http://localhost:7798/health 2>/dev/null)
if [[ $SMRITI_HEALTH == *"ok"* ]]; then
  echo "🧠 SMRITI daemon is already running on port 7798."
else
  echo "🚀 Launching SMRITI daemon on port 7798..."
  python3 scripts/smriti_local_api.py &
  sleep 2
fi

# 2. Check Ollama
OLLAMA_TAGS=$(curl -s http://localhost:11434/api/tags 2>/dev/null)
if [[ -n "$OLLAMA_TAGS" ]]; then
  echo "🦙 Ollama is active on port 11434."
else
  echo "⚠️ Notice: Ollama doesn't seem to be responding on port 11434. Start Ollama if you wish to use local LLMs."
fi

# 3. Open browser after brief pause
(sleep 1 && /usr/bin/open "http://localhost:7800") &

# 4. Start Clicky Web Server
echo "🌐 Starting web server on http://localhost:7800 ..."
python3 web/server.py
