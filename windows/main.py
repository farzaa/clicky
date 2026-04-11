import os
import threading
import tempfile
import base64
import io
import re
import time
import random
import json
import tkinter as tk
from pathlib import Path
import urllib.error
import urllib.request

import av
from faster_whisper import WhisperModel
import sounddevice as sd
import numpy as np
from scipy.io.wavfile import write as wav_write
import mss
from PIL import Image
import pyautogui
from dotenv import load_dotenv

WINDOWS_APP_DIRECTORY = Path(__file__).resolve().parent
load_dotenv(dotenv_path=WINDOWS_APP_DIRECTORY / ".env")
load_dotenv(dotenv_path=WINDOWS_APP_DIRECTORY.parent / ".env")

pyautogui.FAILSAFE = True
pyautogui.PAUSE = 0.0

BACKEND_BASE_URL = os.getenv("DEB_BACKEND_BASE_URL", "http://127.0.0.1:8000").strip()
PARSE_SOURCE_DOCUMENT_PATH = os.getenv("DEB_PARSE_SOURCE_DOCUMENT_PATH", "").strip()
PARSE_SOURCE_DOCUMENT_URL = os.getenv("DEB_PARSE_SOURCE_DOCUMENT_URL", "").strip()
PARSE_OUTPUT_ROOT_DIRECTORY = os.getenv("DEB_PARSE_OUTPUT_ROOT_DIRECTORY", "").strip()
SAMPLE_RATE = 16000
MAX_AGENT_STEPS = 55
FILLERS = ["", "", "", "So, ", "Alright, ", "Okay, ", "Now, ", "Right, "]
whisper_model = None

# State machine:
#   idle       — nothing running
#   recording  — recording initial request
#   running    — agent executing steps
#   listening  — agent paused, recording new instruction
STATE = "idle"

stop_agent = False
new_instruction = None          # set when user speaks mid-task
new_instruction_ready = threading.Event()

audio_chunks = []
stop_audio_flag = threading.Event()

root_window = None
btn_record = None
btn_stop = None
text_log = None


def _run_on_ui_thread(ui_callback):
    if threading.current_thread() is threading.main_thread():
        ui_callback()
        return

    if root_window is None:
        return

    try:
        root_window.after(0, ui_callback)
    except RuntimeError:
        # The window may already be shutting down.
        pass

# ── Prompts ────────────────────────────────────────────────────
PLAN_PROMPT = """You are Clicky, an AI screen tutor. English only.

Look at the screenshot and the user's request. Write a short numbered plan — max 5 steps, plain English. This will be read aloud.

Format:
PLAN:
1. ...
2. ...
"""

STEP_PROMPT = """You are Clicky, an AI screen tutor. English only.

You receive a fresh screenshot before every action. Decide the NEXT single action.

RESPONSE FORMAT (always exactly this):
EXPLAIN: <one natural sentence — what you see and what you will do>
ACTION: [COMMAND]

COMMANDS (coordinates from 1280x720 screenshot):
- [CLICK x=N y=N]
- [RIGHTCLICK x=N y=N]
- [DBLCLICK x=N y=N]
- [MOVE x=N y=N]
- [TYPE text="hello"]
- [KEY key="enter"]
- [WAIT ms=800]
- [SHOWDESKTOP]
- [DONE]

RULES:
1. ONE action only.
2. GUI + MOUSE only. No terminal, no PowerShell.
3. Do not close or minimize windows unnecessarily.
4. After RIGHTCLICK: next action must MOVE to a menu item.
5. [DONE] when fully complete."""

RECONFIG_PROMPT = """You are Clicky, an AI screen tutor. English only.

The user interrupted with a new instruction while you were working. Look at the current screenshot and the new instruction. Decide the NEXT single action — continuing from the current screen state, adjusting to what the user asked.

New instruction: {instruction}

RESPONSE FORMAT:
EXPLAIN: <one sentence: what you will do next based on new instruction>
ACTION: [COMMAND]

Same COMMANDS as before. [DONE] if finished."""


# ── TTS ────────────────────────────────────────────────────────
def speak(text: str):
    if stop_agent or not text.strip():
        return
    safe = text.replace("'", " ").replace('"', " ")
    full = random.choice(FILLERS) + safe
    temporary_audio_file_path = None
    try:
        stop_tts()
        tts_request_payload = {
            "text": full,
            "model_id": "eleven_flash_v2_5",
            "voice_settings": {
                "stability": 0.5,
                "similarity_boost": 0.75,
            },
        }
        tts_audio_data = _post_json_to_backend(
            path="/tts",
            request_payload=tts_request_payload,
            accepted_content_type="audio/mpeg",
            timeout_seconds=60,
        )

        with tempfile.NamedTemporaryFile(suffix=".mp3", delete=False) as temporary_audio_file:
            temporary_audio_file_path = temporary_audio_file.name
            temporary_audio_file.write(tts_audio_data)

        decoded_audio_samples, sample_rate_hz = _decode_tts_audio_file(
            temporary_audio_file_path
        )
        if stop_agent:
            return

        sd.play(decoded_audio_samples, samplerate=sample_rate_hz)
        sd.wait()
    except Exception as e:
        log(f"[TTS error] {e}")
    finally:
        if temporary_audio_file_path and os.path.exists(temporary_audio_file_path):
            try:
                os.unlink(temporary_audio_file_path)
            except Exception:
                pass


def _decode_tts_audio_file(temporary_audio_file_path: str):
    decoded_audio_chunks = []
    decoded_audio_sample_rate_hz = None

    with av.open(temporary_audio_file_path) as audio_container:
        for decoded_audio_frame in audio_container.decode(audio=0):
            decoded_audio_sample_rate_hz = decoded_audio_frame.sample_rate
            decoded_audio_chunk = decoded_audio_frame.to_ndarray()

            # PyAV typically yields audio as [channels, samples], while sounddevice
            # expects [samples, channels].
            if decoded_audio_chunk.ndim == 1:
                decoded_audio_chunk = decoded_audio_chunk.reshape(-1, 1)
            elif (
                decoded_audio_chunk.ndim == 2
                and decoded_audio_chunk.shape[0] <= 8
                and decoded_audio_chunk.shape[0] < decoded_audio_chunk.shape[1]
            ):
                decoded_audio_chunk = decoded_audio_chunk.T

            decoded_audio_chunks.append(
                decoded_audio_chunk.astype(np.float32, copy=False)
            )

    if not decoded_audio_chunks or decoded_audio_sample_rate_hz is None:
        raise RuntimeError("No TTS audio frames were decoded.")

    decoded_audio = np.concatenate(decoded_audio_chunks, axis=0)
    return decoded_audio, decoded_audio_sample_rate_hz


def stop_tts():
    try:
        sd.stop()
    except Exception:
        pass


# ── Whisper ─────────────────────────────────────────────────────
def load_whisper():
    global whisper_model
    if whisper_model is None:
        log("Loading Whisper...")
        whisper_model = WhisperModel("base", device="cpu", compute_type="int8")
        log("Whisper ready!")


def record_until_stopped() -> np.ndarray:
    chunks = []
    stop_audio_flag.clear()
    def cb(indata, frames, t, status):
        chunks.append(indata.copy())
    with sd.InputStream(samplerate=SAMPLE_RATE, channels=1, dtype="int16", callback=cb):
        stop_audio_flag.wait(timeout=120)
    if not chunks:
        return np.zeros((0,1), dtype="int16")
    return np.concatenate(chunks, axis=0)


def transcribe(audio: np.ndarray) -> str:
    load_whisper()
    if audio.shape[0] == 0:
        return ""
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
        wav_write(f.name, SAMPLE_RATE, audio)
        path = f.name
    segs, _ = whisper_model.transcribe(path, language="en")
    os.unlink(path)
    return " ".join(s.text for s in segs).strip()


# ── Screen ──────────────────────────────────────────────────────
def capture_screen():
    with mss.mss() as sct:
        mon = sct.monitors[1]
        shot = sct.grab(mon)
        ow, oh = shot.width, shot.height
        img = Image.frombytes("RGB", shot.size, shot.bgra, "raw", "BGRX")
        img.thumbnail((1280, 720))
        sw, sh = img.size
        buf = io.BytesIO()
        img.save(buf, format="PNG")
        b64 = base64.standard_b64encode(buf.getvalue()).decode()
        return b64, (ow, oh), (sw, sh)


def scale(x, y, orig, scaled):
    return int(x*orig[0]/scaled[0]), int(y*orig[1]/scaled[1])


# ── Mouse ───────────────────────────────────────────────────────
def run_action(cmd, args, orig, scaled):
    try:
        if cmd == "SHOWDESKTOP":
            log("[Show desktop]")
            pyautogui.hotkey("win", "d")
            time.sleep(1.2)
        elif cmd in ("CLICK", "RIGHTCLICK", "DBLCLICK"):
            rx, ry = scale(int(args["x"]), int(args["y"]), orig, scaled)
            pyautogui.moveTo(rx, ry, duration=0.55, tween=pyautogui.easeInOutQuad)
            time.sleep(0.15)
            if cmd == "CLICK":
                log(f"[Click] ({rx},{ry})")
                pyautogui.click(); time.sleep(0.2)
            elif cmd == "RIGHTCLICK":
                log(f"[Right-click] ({rx},{ry})")
                pyautogui.rightClick(); time.sleep(1.2)
            elif cmd == "DBLCLICK":
                log(f"[Double-click] ({rx},{ry})")
                pyautogui.doubleClick(); time.sleep(0.3)
        elif cmd == "MOVE":
            rx, ry = scale(int(args["x"]), int(args["y"]), orig, scaled)
            log(f"[Move] ({rx},{ry})")
            pyautogui.moveTo(rx, ry, duration=0.45, tween=pyautogui.easeInOutQuad)
        elif cmd == "TYPE":
            log(f"[Type] {args.get('text','')}")
            pyautogui.write(args.get("text",""), interval=0.05)
        elif cmd == "KEY":
            k = args.get("key","")
            log(f"[Key] {k}")
            pyautogui.hotkey(*k.split("+")) if "+" in k else pyautogui.press(k)
        elif cmd == "WAIT":
            ms = max(int(args.get("ms",500)), 200)
            log(f"[Wait] {ms}ms"); time.sleep(ms/1000)
    except Exception as e:
        log(f"[Error] {cmd}: {e}")


# ── Claude ──────────────────────────────────────────────────────
def _build_backend_url(path: str) -> str:
    return f"{BACKEND_BASE_URL.rstrip('/')}/{path.lstrip('/')}"


def _post_json_to_backend(
    *,
    path: str,
    request_payload: dict,
    accepted_content_type: str,
    timeout_seconds: int,
) -> bytes:
    backend_url = _build_backend_url(path)
    request_body_data = json.dumps(request_payload).encode("utf-8")
    backend_request = urllib.request.Request(
        url=backend_url,
        data=request_body_data,
        method="POST",
        headers={
            "Content-Type": "application/json",
            "Accept": accepted_content_type,
        },
    )

    try:
        with urllib.request.urlopen(backend_request, timeout=timeout_seconds) as backend_response:
            return backend_response.read()
    except urllib.error.HTTPError as http_error:
        backend_error_response_text = http_error.read().decode("utf-8", errors="replace")
        raise RuntimeError(
            f"Backend request failed ({http_error.code}) at {backend_url}: {backend_error_response_text}"
        ) from http_error
    except urllib.error.URLError as url_error:
        raise RuntimeError(
            f"Could not connect to backend at {backend_url}: {url_error.reason}"
        ) from url_error


def call_claude(messages, system, max_tokens=200):
    chat_request_payload = {
        "model": "claude-opus-4-6",
        "max_tokens": max_tokens,
        "system": system,
        "messages": messages,
    }
    chat_response_data = _post_json_to_backend(
        path="/chat",
        request_payload=chat_request_payload,
        accepted_content_type="application/json",
        timeout_seconds=120,
    )

    try:
        chat_response_payload = json.loads(chat_response_data.decode("utf-8"))
    except json.JSONDecodeError as decode_error:
        raise RuntimeError("Backend /chat returned non-JSON response.") from decode_error

    response_content_blocks = chat_response_payload.get("content", [])
    if not isinstance(response_content_blocks, list):
        raise RuntimeError("Backend /chat returned unexpected content format.")

    for response_content_block in response_content_blocks:
        if (
            isinstance(response_content_block, dict)
            and response_content_block.get("type") == "text"
            and isinstance(response_content_block.get("text"), str)
        ):
            return response_content_block["text"]

    raise RuntimeError("Backend /chat returned no text response content.")


def _extract_parse_topic_from_user_text(user_text: str):
    normalized_user_text = user_text.strip()
    normalized_lowercase_user_text = normalized_user_text.lower()

    if normalized_lowercase_user_text in ("parse", "/parse"):
        return ""

    for parse_command_prefix in ("/parse ", "parse "):
        if normalized_lowercase_user_text.startswith(parse_command_prefix):
            return normalized_user_text[len(parse_command_prefix):].strip()

    return None


def _call_parse_endpoint(topic: str):
    parse_request_payload = {
        "topic": topic,
    }

    if PARSE_SOURCE_DOCUMENT_PATH:
        parse_request_payload["source_document_path"] = PARSE_SOURCE_DOCUMENT_PATH
    elif PARSE_SOURCE_DOCUMENT_URL:
        parse_request_payload["source_document_url"] = PARSE_SOURCE_DOCUMENT_URL
    else:
        raise RuntimeError(
            "Set DEB_PARSE_SOURCE_DOCUMENT_PATH or DEB_PARSE_SOURCE_DOCUMENT_URL in windows/.env first."
        )

    if PARSE_OUTPUT_ROOT_DIRECTORY:
        parse_request_payload["output_root_directory"] = PARSE_OUTPUT_ROOT_DIRECTORY

    parse_response_data = _post_json_to_backend(
        path="/parse",
        request_payload=parse_request_payload,
        accepted_content_type="application/json",
        timeout_seconds=300,
    )

    try:
        parse_response_payload = json.loads(parse_response_data.decode("utf-8"))
    except json.JSONDecodeError as decode_error:
        raise RuntimeError("Backend /parse returned non-JSON response.") from decode_error

    if not isinstance(parse_response_payload, dict):
        raise RuntimeError("Backend /parse returned unexpected response format.")

    return parse_response_payload


def _summarize_parse_response(parse_response_payload: dict):
    parse_status = str(parse_response_payload.get("status", "")).strip().lower()
    parse_message = str(parse_response_payload.get("message", "")).strip()
    topic_markdown_path = str(parse_response_payload.get("topic_markdown_path", "")).strip()

    if parse_status in ("success", "success_cached"):
        if topic_markdown_path:
            return f"Parse complete. Topic markdown saved to {topic_markdown_path}."
        return "Parse complete."

    if parse_message:
        return f"Parse failed. {parse_message}"

    return "Parse failed."


def parse_response(resp):
    explain, cmd_name, args, is_done = "", None, {}, False
    m = re.search(r'EXPLAIN:\s*(.+)', resp)
    if m: explain = m.group(1).strip()
    a = re.search(r'ACTION:\s*\[(\w+)\s*([^\]]*)\]', resp)
    if a:
        cmd_name = a.group(1)
        for kv in re.finditer(r'(\w+)=(?:"([^"]*)"|([\d]+))', a.group(2)):
            args[kv.group(1)] = kv.group(2) if kv.group(2) else kv.group(3)
        if cmd_name == "DONE":
            is_done = True
    return explain, cmd_name, args, is_done


# ── Button handler ──────────────────────────────────────────────
def on_record_btn():
    global STATE
    if STATE == "idle":
        _start_recording()
    elif STATE == "recording":
        _stop_recording()
    elif STATE == "running":
        _pause_and_listen()
    elif STATE == "listening":
        _finish_listening()


def _set_state(s):
    global STATE
    STATE = s
    colors = {"idle": "#3B82F6", "recording": "#F59E0B",
              "running": "#10B981", "listening": "#8B5CF6"}

    def update_state_buttons():
        if btn_record is None or btn_stop is None:
            return
        try:
            btn_record.config(bg=colors[s], text="Listen")
            btn_stop.config(state="normal" if s in ("running", "listening") else "disabled")
        except tk.TclError:
            pass

    _run_on_ui_thread(update_state_buttons)


def _start_recording():
    _set_state("recording")
    threading.Thread(target=_recording_thread, daemon=True).start()


def _stop_recording():
    stop_audio_flag.set()
    # thread will pick it up


def _pause_and_listen():
    global new_instruction
    stop_tts()                      # kill speech immediately
    new_instruction = None
    new_instruction_ready.clear()
    _set_state("listening")
    log("Listening...")
    threading.Thread(target=_listen_thread, daemon=True).start()


def _finish_listening():
    stop_audio_flag.set()


def on_stop():
    global stop_agent
    stop_agent = True
    stop_tts()
    stop_audio_flag.set()
    new_instruction_ready.set()
    log("Stopped.")


# ── Threads ──────────────────────────────────────────────────────
def _recording_thread():
    audio = record_until_stopped()
    _set_state("running")
    threading.Thread(target=_agent_thread, args=(audio,), daemon=True).start()


def _listen_thread():
    global new_instruction
    audio = record_until_stopped()
    text = transcribe(audio)
    new_instruction = text
    log(f"New instruction: {text}")
    new_instruction_ready.set()
    _set_state("running")


# ── Agent ────────────────────────────────────────────────────────
def interrupted():
    """True if user clicked Record (listen) or Stop mid-task."""
    return STATE == "listening" or stop_agent


def wait_for_listen_and_reconfig(messages, task):
    """Block until user finishes speaking, speak back confirmation + new plan, return updated task."""
    global new_instruction
    new_instruction_ready.wait(timeout=60)
    new_instruction_ready.clear()
    if stop_agent:
        return task
    if not new_instruction:
        speak("I didn't catch that. Let me continue with what I was doing.")
        return task

    updated_task = new_instruction
    new_instruction = None
    log(f"New instruction: {updated_task}")

    # Speak back confirmation
    speak(f"Got it. You said: {updated_task}")
    if stop_agent: return updated_task

    # Take fresh screenshot and make a new plan
    log("Replanning...")
    b64, orig, scaled = capture_screen()
    if stop_agent: return updated_task

    plan_resp = call_claude(
        [{"role": "user", "content": [
            {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": b64}},
            {"type": "text", "text": f"New instruction from user: {updated_task}"},
        ]}],
        system=PLAN_PROMPT,
    )
    log(f"New plan:\n{plan_resp}")
    plan_text = re.sub(r'PLAN:\s*', '', plan_resp).strip()
    if plan_text and not stop_agent:
        speak(f"Here's my new plan. {plan_text}")

    return updated_task


def _agent_thread(audio: np.ndarray):
    global stop_agent, new_instruction

    stop_agent = False
    new_instruction = None

    try:
        user_text = transcribe(audio)
        if not user_text:
            log("No speech detected.")
            return
        log(f"You: {user_text}")

        if interrupted(): return

        parse_topic = _extract_parse_topic_from_user_text(user_text)
        if parse_topic is not None:
            if not parse_topic:
                usage_message = (
                    "Say parse followed by a topic, for example: parse chapter one limits."
                )
                log(usage_message)
                speak(usage_message)
                return

            log(f"Parsing topic via /parse: {parse_topic}")
            parse_response_payload = _call_parse_endpoint(parse_topic)
            parse_summary = _summarize_parse_response(parse_response_payload)
            log(parse_summary)
            speak(parse_summary)
            return

        # Plan
        log("Planning...")
        b64, orig, scaled = capture_screen()
        if interrupted(): return

        plan_resp = call_claude(
            [{"role":"user","content":[
                {"type":"image","source":{"type":"base64","media_type":"image/png","data":b64}},
                {"type":"text","text":f"User request: {user_text}"},
            ]}],
            system=PLAN_PROMPT,
        )
        if interrupted(): return

        log(f"Plan:\n{plan_resp}")
        plan_text = re.sub(r'PLAN:\s*', '', plan_resp).strip()
        if plan_text:
            speak(f"Here's my plan. {plan_text}")

        if interrupted(): return

        messages = []
        task = user_text
        step = 0

        while step < MAX_AGENT_STEPS:

            # ── Immediate interrupt check ─────────────────────
            if stop_agent:
                break

            if STATE == "listening":
                task = wait_for_listen_and_reconfig(messages, task)
                if stop_agent: break
                # Reset to fresh context with new task
                messages = []
                _set_state("running")
                continue  # restart loop with new task

            step += 1
            log(f"--- Step {step} ---")

            time.sleep(0.3)
            if interrupted(): break

            b64, orig, scaled = capture_screen()
            if interrupted(): break

            content = [
                {"type":"image","source":{"type":"base64","media_type":"image/png","data":b64}},
                {"type":"text","text":f"Task: {task}" if step==1 else "Current screen. Next action?"},
            ]
            messages.append({"role":"user","content":content})

            log("Thinking...")
            resp = call_claude(messages, system=STEP_PROMPT)
            messages.append({"role":"assistant","content":resp})

            if interrupted(): break

            explain, cmd_name, args, is_done = parse_response(resp)
            log(f"  {explain}")

            if explain:
                speak(explain)      # stop_tts() will cut this short if interrupted

            if interrupted(): break

            if is_done or not cmd_name:
                speak("Done! The task is complete.")
                log("Done!")
                break

            run_action(cmd_name, args, orig, scaled)

            if interrupted(): break

        if step >= MAX_AGENT_STEPS and not stop_agent:
            speak("I've done my best. Let me know if you need more.")

    except Exception as e:
        log(f"Error: {e}")
    finally:
        _set_state("idle")


# ── UI ────────────────────────────────────────────────────────────
def log(msg: str):
    def append_log_message():
        if text_log is None:
            return
        try:
            text_log.config(state="normal")
            text_log.insert("end", msg + "\n")
            text_log.see("end")
            text_log.config(state="disabled")
        except tk.TclError:
            pass

    _run_on_ui_thread(append_log_message)
    print(msg)


def main():
    global btn_record, btn_stop, text_log, root_window

    root = tk.Tk()
    root_window = root
    root.title("Clicky - AI Assistant")
    root.geometry("440x340")
    root.resizable(False, False)
    root.attributes("-topmost", True)

    tk.Label(root, text="Clicky", font=("Segoe UI", 18, "bold"), fg="#3B82F6").pack(pady=(14,2))
    tk.Label(root, text="AI Screen Assistant", font=("Segoe UI", 10), fg="#6B7280").pack()

    bf = tk.Frame(root); bf.pack(pady=12)

    btn_record = tk.Button(
        bf, text="Listen",
        # Blue=idle, Yellow=recording, Green=running, Purple=listening-for-instruction
        font=("Segoe UI", 12, "bold"),
        bg="#3B82F6", fg="white",
        activebackground="#2563EB", activeforeground="white",
        relief="flat", padx=22, pady=10,
        cursor="hand2", command=on_record_btn,
    )
    btn_record.pack(side="left", padx=6)

    btn_stop = tk.Button(
        bf, text="Stop",
        font=("Segoe UI", 12, "bold"),
        bg="#EF4444", fg="white",
        activebackground="#DC2626", activeforeground="white",
        relief="flat", padx=22, pady=10,
        cursor="hand2", state="disabled",
        command=on_stop,
    )
    btn_stop.pack(side="left", padx=6)

    tk.Label(root, text="Log:", font=("Segoe UI", 9), fg="#6B7280").pack(anchor="w", padx=16)
    text_log = tk.Text(
        root, height=11, font=("Consolas", 9),
        bg="#F9FAFB", fg="#111827",
        state="disabled", relief="flat", bd=0,
    )
    text_log.pack(fill="both", padx=16, pady=(0,14))

    log("Clicky ready.")
    log(f"Backend: {BACKEND_BASE_URL}")
    if PARSE_SOURCE_DOCUMENT_PATH:
        log(f"Parse source path: {PARSE_SOURCE_DOCUMENT_PATH}")
    elif PARSE_SOURCE_DOCUMENT_URL:
        log(f"Parse source URL: {PARSE_SOURCE_DOCUMENT_URL}")
    else:
        log("Parse source not set. Configure DEB_PARSE_SOURCE_DOCUMENT_PATH or DEB_PARSE_SOURCE_DOCUMENT_URL for /parse.")
    log("  Blue=idle  Yellow=recording  Green=running  Purple=listening")
    log("  Click Listen anytime — it always listens to you.")
    threading.Thread(target=load_whisper, daemon=True).start()
    root.mainloop()


if __name__ == "__main__":
    main()
