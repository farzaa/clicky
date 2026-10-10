#!/usr/bin/env python3
"""
Clicky Web Companion Server
Runs a local web interface on localhost:7799 with:
- SMRITI Long-Term Memory integration (via localhost:7798)
- Local Ollama AI chat (Mistral, Qwen 3.5 Vision, etc.)
- Native macOS silent screen capture via screencapture CLI
- Browser-based Voice input (Speech-to-Text) and Text-to-Speech with full stop/mute control
"""

import os
import sys
import json
import base64
import subprocess
import urllib.request
import urllib.error
from datetime import datetime
from http.server import HTTPServer, BaseHTTPRequestHandler
from pathlib import Path

PORT = 7800
SMRITI_API_URL = "http://localhost:7798"
OLLAMA_API_URL = "http://localhost:11434"
SCREENSHOT_PATH = "/tmp/clicky_web_screen.jpg"
WEB_DIR = Path(__file__).parent.resolve()

def capture_screen():
    """Captures the active screen silently using native macOS screencapture CLI."""
    try:
        # -x: mute sound, -t jpg: save as JPEG
        subprocess.run(["screencapture", "-x", "-t", "jpg", SCREENSHOT_PATH], check=True, capture_output=True)
        # Downscale retina capture to max 1280px to slash vision tokens and avoid timeouts
        subprocess.run(["sips", "-Z", "1280", SCREENSHOT_PATH], capture_output=True)
        if os.path.exists(SCREENSHOT_PATH) and os.path.getsize(SCREENSHOT_PATH) > 0:
            with open(SCREENSHOT_PATH, "rb") as f:
                img_data = f.read()
            return base64.b64encode(img_data).decode("utf-8")
    except Exception as e:
        print(f"⚠️ Error capturing screen: {e}")
    return None

def query_smriti_recall(query, limit=4):
    """Recalls relevant memories from SMRITI API."""
    try:
        req = urllib.request.Request(
            f"{SMRITI_API_URL}/recall",
            data=json.dumps({"query": query, "top_k": limit}).encode("utf-8"),
            headers={"Content-Type": "application/json"}
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            return data.get("memories", [])
    except Exception as e:
        print(f"⚠️ Smriti recall warning: {e}")
        return []

def encode_smriti_memory(content, modality="text"):
    """Encodes a conversation turn into SMRITI."""
    try:
        req = urllib.request.Request(
            f"{SMRITI_API_URL}/encode",
            data=json.dumps({
                "content": content,
                "source": "direct",
                "modality": modality
            }).encode("utf-8"),
            headers={"Content-Type": "application/json"}
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except Exception as e:
        print(f"⚠️ Smriti encode warning: {e}")
        return None

def get_ollama_models():
    """Gets available models from local Ollama."""
    try:
        req = urllib.request.Request(f"{OLLAMA_API_URL}/api/tags")
        with urllib.request.urlopen(req, timeout=2) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            return [m["name"] for m in data.get("models", [])]
    except Exception:
        return []

def query_ollama(model, system_prompt, user_prompt, image_b64=None):
    """Sends chat completion request to Ollama."""
    messages = [
        {"role": "system", "content": system_prompt}
    ]

    is_vision = any(k in model.lower() for k in ["vision", "vl", "pixtral", "llava", "qwen3.5", "minicpm"])
    
    if is_vision and image_b64:
        content_blocks = [
            {"type": "text", "text": user_prompt},
            {
                "type": "image_url",
                "image_url": {"url": f"data:image/jpeg;base64,{image_b64}"}
            }
        ]
        messages.append({"role": "user", "content": content_blocks})
    else:
        full_text = user_prompt
        if image_b64 and not is_vision:
            full_text += "\n[Note: User has their screen captured, but current model is text-only. Answer based on question and context.]"
        messages.append({"role": "user", "content": full_text})

    payload = {
        "model": model,
        "messages": messages,
        "stream": False,
        "temperature": 0.7
    }

    req = urllib.request.Request(
        f"{OLLAMA_API_URL}/v1/chat/completions",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"}
    )
    with urllib.request.urlopen(req, timeout=180) as resp:
        res = json.loads(resp.read().decode("utf-8"))
        choices = res.get("choices", [])
        if choices:
            return choices[0].get("message", {}).get("content", "")
        return ""

class ClickyWebHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        # Keep terminal clean, log only API queries
        if args and isinstance(args[0], str) and "/api/" in args[0]:
            print(f"🌐 [ClickyWeb] {args[0]}")

    def send_cors_headers(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")

    def do_OPTIONS(self):
        self.send_response(200)
        self.send_cors_headers()
        self.end_headers()

    def do_GET(self):
        clean_path = self.path.split("?")[0]
        if clean_path == "/" or clean_path == "/index.html":
            index_file = WEB_DIR / "index.html"
            if index_file.exists():
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_cors_headers()
                self.end_headers()
                with open(index_file, "rb") as f:
                    self.wfile.write(f.read())
            else:
                self.send_response(404)
                self.end_headers()
                self.wfile.write(b"index.html not found")

        elif clean_path == "/api/status":
            models = get_ollama_models()
            smriti_stats = {}
            try:
                req = urllib.request.Request(f"{SMRITI_API_URL}/health")
                with urllib.request.urlopen(req, timeout=2) as resp:
                    smriti_stats = json.loads(resp.read().decode("utf-8"))
            except Exception:
                pass

            data = {
                "ollama_running": len(models) > 0,
                "models": models,
                "smriti_connected": smriti_stats.get("status") == "ok",
                "smriti_memories": smriti_stats.get("memories_count", 0),
                "has_screenshot": os.path.exists(SCREENSHOT_PATH)
            }
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_cors_headers()
            self.end_headers()
            self.wfile.write(json.dumps(data).encode("utf-8"))

        elif clean_path == "/api/screenshot":
            if os.path.exists(SCREENSHOT_PATH):
                self.send_response(200)
                self.send_header("Content-Type", "image/jpeg")
                self.send_cors_headers()
                self.end_headers()
                with open(SCREENSHOT_PATH, "rb") as f:
                    self.wfile.write(f.read())
            else:
                self.send_response(404)
                self.end_headers()

        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        if self.path == "/api/capture":
            b64 = capture_screen()
            self.send_response(200 if b64 else 500)
            self.send_header("Content-Type", "application/json")
            self.send_cors_headers()
            self.end_headers()
            self.wfile.write(json.dumps({
                "status": "ok" if b64 else "error",
                "has_image": b64 is not None,
                "image_data": f"data:image/jpeg;base64,{b64}" if b64 else None
            }).encode("utf-8"))

        elif self.path == "/api/chat":
            content_length = int(self.headers.get("Content-Length", 0))
            body_bytes = self.rfile.read(content_length)
            try:
                body = json.loads(body_bytes.decode("utf-8"))
            except Exception:
                body = {}

            prompt = body.get("prompt", "").strip()
            model = body.get("model", "qwen3.5:latest")
            include_screen = body.get("include_screen", True)
            image_b64 = body.get("image_b64")

            if not prompt:
                self.send_response(400)
                self.send_header("Content-Type", "application/json")
                self.send_cors_headers()
                self.end_headers()
                self.wfile.write(json.dumps({"error": "Empty prompt"}).encode("utf-8"))
                return

            # Capture screen if requested and not provided manually
            if include_screen and not image_b64:
                image_b64 = capture_screen()

            # Recall from SMRITI
            memories = query_smriti_recall(prompt, limit=4)
            recalled_context = ""
            if memories:
                recalled_context = "\n\n[RECALLED SMRITI MEMORIES]:\n" + "\n".join(
                    [f"- {m.get('content', '')}" for m in memories]
                )

            now_str = datetime.now().strftime("%A, %B %d, %Y, %I:%M %p")
            system_prompt = (
                f"You are Clicky, a friendly, intelligent AI companion with persistent long-term memory via SMRITI.\n"
                f"Today is: {now_str}.\n"
                f"You can see what the user is working on if a screen capture is attached.\n"
                f"Be direct, insightful, and clear. If referring to code or visual elements on screen, describe them precisely.\n"
                f"Keep responses conversational and readable."
            ) + recalled_context

            try:
                reply = query_ollama(model=model, system_prompt=system_prompt, user_prompt=prompt, image_b64=image_b64)
                if not reply:
                    reply = "I received your message, but didn't get a response from the model. Make sure Ollama is running."

                # Encode exchange to SMRITI
                encode_text = f"User asked: {prompt}\nClicky answered: {reply[:300]}"
                encode_smriti_memory(encode_text, modality="text")

                response_data = {
                    "reply": reply,
                    "model": model,
                    "recalled_memories": memories,
                    "has_screenshot": image_b64 is not None
                }

                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_cors_headers()
                self.end_headers()
                self.wfile.write(json.dumps(response_data).encode("utf-8"))
            except Exception as e:
                self.send_response(500)
                self.send_header("Content-Type", "application/json")
                self.send_cors_headers()
                self.end_headers()
                self.wfile.write(json.dumps({"error": str(e)}).encode("utf-8"))

        else:
            self.send_response(404)
            self.end_headers()

def run_server():
    server_address = ("127.0.0.1", PORT)
    httpd = HTTPServer(server_address, ClickyWebHandler)
    print(f"✨ Clicky Web Companion running at http://localhost:{PORT}")
    print(f"🧠 SMRITI Memory linked at {SMRITI_API_URL}")
    print(f"🦙 Ollama AI linked at {OLLAMA_API_URL}")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nStopping Clicky Web Server...")
        httpd.server_close()

if __name__ == "__main__":
    run_server()
