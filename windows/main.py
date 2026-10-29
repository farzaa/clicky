import os
import sys
import asyncio
import threading
import tempfile
import base64
import io
import re
import time
import random
import tkinter as tk
import subprocess

import anthropic
import edge_tts
from faster_whisper import WhisperModel
import sounddevice as sd
import numpy as np
from scipy.io.wavfile import write as wav_write
import mss
from PIL import Image
import pyautogui
from dotenv import load_dotenv

load_dotenv()

pyautogui.FAILSAFE = True
pyautogui.PAUSE = 0.0

ANTHROPIC_API_KEY = os.getenv("ANTHROPIC_API_KEY")
SAMPLE_RATE = 16000
MAX_AGENT_STEPS = 55
TTS_VOICE = "en-US-AriaNeural"
FILLERS = ["", "", "", "So, ", "Alright, ", "Okay, ", "Now, ", "Right, "]

client = anthropic.Anthropic(api_key=ANTHROPIC_API_KEY)
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
_tts_proc = None

root_window = None

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
    global _tts_proc
    if stop_agent or not text.strip():
        return
    safe = text.replace("'", " ").replace('"', " ")
    full = random.choice(FILLERS) + safe
    try:
        tmp = tempfile.mktemp(suffix=".mp3")
        asyncio.run(edge_tts.Communicate(full, voice=TTS_VOICE).save(tmp))
        _tts_proc = subprocess.Popen(
            ["ffplay", "-nodisp", "-autoexit", "-loglevel", "quiet", tmp],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        _tts_proc.wait()
        try: os.unlink(tmp)
        except: pass
    except Exception as e:
        log(f"[TTS error] {e}")


def stop_tts():
    global _tts_proc
    if _tts_proc and _tts_proc.poll() is None:
        _tts_proc.kill()


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
def call_claude(messages, system, max_tokens=200):
    r = client.messages.create(
        model="claude-opus-4-6", max_tokens=max_tokens,
        system=system, messages=messages,
    )
    return r.content[0].text


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
    btn_record.config(bg=colors[s], text="Listen")
    btn_stop.config(state="normal" if s in ("running","listening") else "disabled")


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
        btn_stop.config(state="disabled")


# ── UI ────────────────────────────────────────────────────────────
def log(msg: str):
    text_log.config(state="normal")
    text_log.insert("end", msg + "\n")
    text_log.see("end")
    text_log.config(state="disabled")
    print(msg)


def main():
    if not ANTHROPIC_API_KEY:
        print("ERROR: ANTHROPIC_API_KEY not found.")
        sys.exit(1)

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
    log("  Blue=idle  Yellow=recording  Green=running  Purple=listening")
    log("  Click Listen anytime — it always listens to you.")
    threading.Thread(target=load_whisper, daemon=True).start()
    root.mainloop()


if __name__ == "__main__":
    main()
