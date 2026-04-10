import test from "node:test";
import assert from "node:assert/strict";

function loadVoiceModule() {
  return import(`../src/voice.js?voice-test=${Date.now()}-${Math.random()}`);
}

function createSocket() {
  return {
    readyState: 1,
    sent: [],
    send(payload) {
      this.sent.push(JSON.parse(payload));
    },
  };
}

test("handleSocketDisconnect releases active recorder and stream state", async () => {
  const track = {
    stopCalls: 0,
    stop() {
      this.stopCalls += 1;
    },
  };

  const stream = {
    getTracks() {
      return [track];
    },
  };

  class FakeMediaRecorder {
    constructor(inputStream) {
      this.inputStream = inputStream;
      this.state = "inactive";
      this.ondataavailable = null;
    }

    start() {
      this.state = "recording";
    }

    stop() {
      this.state = "inactive";
    }
  }

  Object.defineProperty(globalThis, "navigator", {
    configurable: true,
    value: {
      mediaDevices: {
        async getUserMedia() {
          return stream;
        },
      },
    },
  });

  Object.defineProperty(globalThis, "MediaRecorder", {
    configurable: true,
    value: FakeMediaRecorder,
  });

  Object.defineProperty(globalThis, "localStorage", {
    configurable: true,
    value: {
      getItem() {
        return null;
      },
    },
  });

  const voice = await loadVoiceModule();
  const socket = createSocket();
  let ref = 0;

  await voice.startListening(socket, () => String(++ref));

  assert.equal(voice.isVoiceSessionActive(), true);

  voice.handleSocketDisconnect();

  assert.equal(voice.isVoiceSessionActive(), false);
  assert.equal(track.stopCalls, 1);
});
