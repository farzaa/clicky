# Grounding Eval Cases

Keep real screenshots and guide JSON captures out of git. This folder is for local, synthetic, public, or explicitly consented cases only.

Each local case is a JSON file:

```json
{
  "name": "objective-selection",
  "screenshot": "./objective-selection.png",
  "guide": "./objective-selection-guide.json",
  "reason": "optional rejection reason"
}
```

Run:

```sh
node worker/evals/run-grounding-evals.mjs
```

The generated HTML index lands in `worker/evals/reports/index.html`. These evals are a visual crash test, not a source of truth for any ad platform UI.
