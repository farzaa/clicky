# Grounding Replay Fixtures

Keep real screenshots and guide JSON captures out of git. Use this folder for local, disposable fixtures only.

Example:

```sh
node worker/evals/replay-grounding.mjs \
  --screenshot worker/evals/fixtures/local-screen.png \
  --guide worker/evals/fixtures/local-guide.json \
  --out worker/evals/reports/latest.html
```

The replay is a crash test for the current Vision grounding output. It is not a UI corpus, a pixel map, or a source of truth for Meta's interface.
