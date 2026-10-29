# Local Worker Development

This app is configured to call the local Worker at `http://127.0.0.1:8787`.

## Setup

1. Fill in real API keys in `worker/.dev.vars`.
2. Install Worker dependencies:

```bash
npm install
```

3. Start the local Worker:

```bash
npx wrangler dev
```

4. Run the macOS app from Xcode using the `leanring-buddy` scheme.

Do not run `xcodebuild` from the terminal for this project, because it can disturb macOS privacy permissions.

## What The Keys Do

- `OPENAI_API_KEY`: sends the screen plus transcript to OpenAI, transcribes push-to-talk audio, and generates spoken reply audio.
