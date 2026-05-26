---
title: YardTalk Privacy Policy
---

# YardTalk Privacy Policy

**Effective date:** 2026-05-20
**Last updated:** 2026-05-20

YardTalk ("the app") is a macOS menu bar app that records short narrated screen clips during work sessions and synthesizes them into per-project reports. This policy explains what data the app handles, where it goes, and the controls you have over it.

## TL;DR

- Recordings, transcripts, and screenshots are stored **locally** on your Mac. The app does not upload them to YardTalk servers — there are no YardTalk servers.
- Transcription runs **on-device** using Apple's Neural Engine. Audio is not sent to a cloud transcription service.
- Synthesis (turning your narration and clips into a report) is performed by **Anthropic Claude** using **your own API key**. Your narration and clip context are sent to Anthropic only when you trigger synthesis.
- Pushing a session summary to your personal assistant (NeighborhoodUnited / "NU") is **opt-in per session**. Only the structured summary is pushed — never raw clips, transcripts, or screenshots.
- Nothing leaves your Mac without an explicit, recent decision by you.

## Information the app handles

### Created and stored locally on your Mac
- **Screen recordings (MP4)** captured via macOS `ScreenCaptureKit` while you hold the record hotkey.
- **Microphone audio** baked into the recording.
- **Transcripts** generated locally from the audio.
- **Project metadata** you create (project names, templates, session notes).
- **Synthesized session reports** produced by Claude.

These artifacts live in YardTalk's local application data directory and are not transmitted by the app to any third party except as described below.

### Stored in your macOS Keychain
- **Your Anthropic API key**, if you choose to enter one.
- **Your NeighborhoodUnited Personal Access Token (PAT)**, if you choose to connect a NU instance.

These are stored using Apple's Keychain Services and never transmitted to YardTalk.

### Not collected
- No analytics, telemetry, crash reporting, advertising IDs, or usage tracking.
- No account system. The app has no concept of a YardTalk user account because there is no YardTalk backend.

## Third-party services

YardTalk only contacts external services when you take an action that requires them.

### Anthropic (Claude API) — synthesis
When you trigger synthesis at the end of a session, the app sends your narration transcript and structured clip context to Anthropic's API using **your own API key**. Your data is governed by Anthropic's [Privacy Policy](https://www.anthropic.com/legal/privacy) and [Commercial Terms](https://www.anthropic.com/legal/commercial-terms) under your API key.

### NeighborhoodUnited (your personal assistant) — optional push
If you configure NU and explicitly choose to push a session, the app sends a structured JSON summary (project name, time range, summary, accomplishments, blockers, next steps) to the NU endpoint you have configured, authenticated with your PAT. **Raw clips, transcripts, and screenshots are never pushed.** NU is a service you operate or have access to; YardTalk does not control it.

### FluidAudio / Parakeet (CoreML) — local
Transcription uses a CoreML model that runs on-device on the Apple Neural Engine. No audio leaves your Mac for transcription.

## macOS permissions

YardTalk asks the operating system for the following permissions, each of which you grant or revoke in System Settings:
- **Screen Recording** — to capture the screen region you record.
- **Microphone** — to record your narration.
- **Accessibility** — to register the global record hotkey.

These are used only while recording and only at your direction.

## Your controls

- **Per-session decision:** At the end of every session you choose one of: push to NU, queue for later, or keep local (or delete).
- **Delete locally:** Recordings, transcripts, and reports can be deleted from within the app or by removing the app's data directory.
- **Revoke credentials:** Remove your Anthropic API key or NU PAT from the app's settings; the corresponding Keychain item is deleted.
- **Revoke permissions:** Revoke Screen Recording, Microphone, or Accessibility access in System Settings → Privacy & Security at any time.

## Children

YardTalk is not directed to children under 13 and does not knowingly collect information from them.

## Changes to this policy

If this policy changes, the updated version will be published at the same URL with a new "Last updated" date. Material changes will be noted in the app's release notes.

## Contact

Questions or requests about this policy: **mj1@duck.com**
