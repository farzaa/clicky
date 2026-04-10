// Voice module — mic capture, companion:voice channel, TTS playback

/** @type {MediaRecorder|null} */
let recorder = null;
/** @type {MediaStream|null} */
let stream = null;
/** @type {boolean} */
let isListening = false;
/** @type {HTMLAudioElement|null} */
let ttsAudio = null;
/** @type {string|null} */
let ttsObjectUrl = null;

let onStatusChange = () => {};
let onTranscript = () => {};
let onResponse = () => {};
let onError = () => {};

function isSocketOpen(socket) {
  return !!socket && socket.readyState === 1;
}

function cleanupCaptureState() {
  if (recorder && recorder.state !== "inactive") {
    recorder.stop();
  }
  recorder = null;

  if (stream) {
    stream.getTracks().forEach((track) => track.stop());
    stream = null;
  }

  isListening = false;
}

export function configure(callbacks) {
  if (callbacks.onStatusChange) onStatusChange = callbacks.onStatusChange;
  if (callbacks.onTranscript) onTranscript = callbacks.onTranscript;
  if (callbacks.onResponse) onResponse = callbacks.onResponse;
  if (callbacks.onError) onError = callbacks.onError;
}

let voiceJoinRef = null;

export function joinVoiceChannel(socket, nextRef) {
  voiceJoinRef = nextRef();
  const joinMsg = [voiceJoinRef, nextRef(), "companion:voice", "phx_join", {}];
  socket.send(JSON.stringify(joinMsg));
  return voiceJoinRef;
}

export function leaveVoiceChannel(socket, nextRef) {
  if (voiceJoinRef) {
    const leaveMsg = [voiceJoinRef, nextRef(), "companion:voice", "phx_leave", {}];
    socket.send(JSON.stringify(leaveMsg));
    voiceJoinRef = null;
  }
}

export function handleVoiceEvent(eventName, payload) {
  switch (eventName) {
    case "voice_transcript":
      onTranscript(payload.text, payload.final);
      break;
    case "voice_response":
      onResponse(payload.text);
      onStatusChange("connected");
      break;
    case "tts_audio":
      playTtsAudio(payload.data);
      break;
    case "voice_error":
      onError(payload.message);
      onStatusChange("connected");
      break;
  }
}

export async function startListening(socket, nextRef) {
  if (isListening) return;
  isListening = true;
  onStatusChange("listening");

  try {
    const deviceId = localStorage.getItem("audio_input") || undefined;
    const constraints = {
      audio: deviceId ? { deviceId: { exact: deviceId } } : true,
    };

    stream = await navigator.mediaDevices.getUserMedia(constraints);

    if (!voiceJoinRef) {
      joinVoiceChannel(socket, nextRef);
    }

    const startMsg = [voiceJoinRef, nextRef(), "companion:voice", "start_session", {}];
    socket.send(JSON.stringify(startMsg));

    recorder = new MediaRecorder(stream, { mimeType: "audio/webm;codecs=opus" });

    recorder.ondataavailable = async (event) => {
      if (event.data.size > 0 && isSocketOpen(socket) && voiceJoinRef) {
        const buffer = await event.data.arrayBuffer();
        const bytes = new Uint8Array(buffer);
        let binary = '';
        for (let i = 0; i < bytes.length; i++) {
          binary += String.fromCharCode(bytes[i]);
        }
        const base64 = btoa(binary);
        const frameMsg = [
          voiceJoinRef,
          nextRef(),
          "companion:voice",
          "audio_frame",
          { data: base64 },
        ];
        socket.send(JSON.stringify(frameMsg));
      }
    };

    recorder.start(250);
  } catch (err) {
    isListening = false;
    onError(`Mic access failed: ${err.message}`);
    onStatusChange("connected");
  }
}

export function stopListening(socket, nextRef) {
  if (!isListening && !recorder && !stream) return;

  if (isListening) {
    onStatusChange("processing");
  }

  if (isSocketOpen(socket) && voiceJoinRef) {
    const stopMsg = [voiceJoinRef, nextRef(), "companion:voice", "stop_session", {}];
    socket.send(JSON.stringify(stopMsg));
  } else {
    voiceJoinRef = null;
  }

  cleanupCaptureState();
}

export function handleSocketDisconnect() {
  cleanupCaptureState();
  voiceJoinRef = null;
}

export function isVoiceSessionActive() {
  return isListening || !!recorder || !!stream;
}

function playTtsAudio(base64Data) {
  const binary = atob(base64Data);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }

  const blob = new Blob([bytes], { type: "audio/mpeg" });
  ttsObjectUrl = URL.createObjectURL(blob);

  ttsAudio = new Audio(ttsObjectUrl);

  const outputDevice = localStorage.getItem("audio_output");
  if (outputDevice && typeof ttsAudio.setSinkId === "function") {
    ttsAudio.setSinkId(outputDevice).catch((err) => {
      console.warn("[voice] Could not set output device:", err);
    });
  }

  ttsAudio.onended = () => {
    URL.revokeObjectURL(ttsObjectUrl);
    ttsObjectUrl = null;
  };
  ttsAudio.play().catch((err) => {
    console.warn("[voice] TTS playback failed:", err);
    URL.revokeObjectURL(ttsObjectUrl);
    ttsObjectUrl = null;
  });
}

export function stopTts() {
  if (ttsAudio) {
    ttsAudio.pause();
    ttsAudio = null;
  }
  if (ttsObjectUrl) {
    URL.revokeObjectURL(ttsObjectUrl);
    ttsObjectUrl = null;
  }
}
