import test from "node:test";
import assert from "node:assert/strict";

function loadAuthModule() {
  return import(`../src/auth.js?auth-test=${Date.now()}-${Math.random()}`);
}

function createLocalStorage() {
  const data = new Map();

  return {
    getItem(key) {
      return data.has(key) ? data.get(key) : null;
    },
    setItem(key, value) {
      data.set(key, String(value));
    },
    removeItem(key) {
      data.delete(key);
    },
    clear() {
      data.clear();
    },
  };
}

test("scheduleTokenExpiry clears stored auth without starting interactive login", async () => {
  const calls = [];
  const storage = createLocalStorage();
  let scheduledCallback = null;

  storage.setItem("token_expires_at", String(Date.now() + 60_000));

  Object.defineProperty(globalThis, "localStorage", {
    configurable: true,
    value: storage,
  });

  Object.defineProperty(globalThis, "window", {
    configurable: true,
    value: {
      __TAURI__: {
        core: {
          async invoke(command) {
            calls.push(command);
            return null;
          },
        },
      },
    },
  });

  const originalSetTimeout = globalThis.setTimeout;
  const originalClearTimeout = globalThis.clearTimeout;

  globalThis.setTimeout = (callback) => {
    scheduledCallback = callback;
    return 1;
  };
  globalThis.clearTimeout = () => {};

  try {
    const auth = await loadAuthModule();
    let expired = false;

    auth.scheduleTokenExpiry(120, () => {
      expired = true;
    });

    assert.equal(typeof scheduledCallback, "function");

    await scheduledCallback();

    assert.equal(expired, true);
    assert.equal(storage.getItem("token_expires_at"), null);
    assert.deepEqual(calls, ["keyring_delete"]);
  } finally {
    globalThis.setTimeout = originalSetTimeout;
    globalThis.clearTimeout = originalClearTimeout;
  }
});
