# AGENTS.md - Spider App Target

Use the repository-level `AGENTS.md` as the source of truth. This target keeps
the legacy folder and scheme name, but the product is Spider.

Target-specific reminders:

- Do not persist screenshots, transcripts, prompts, model responses, emails, magic links, or session tokens outside their approved stores.
- Session tokens and the stable device identifier belong in Keychain.
- Ad Mission state, artifacts, and decision memory belong in `Application Support/Spider/AdMission.json`.
- Screen guidance must go through the authenticated Worker.
- OpenAI Realtime client secrets must come from the Worker.
- Do not re-enable Anthropic, AssemblyAI, ElevenLabs, PostHog, or direct client-side OpenAI audio uploads.
