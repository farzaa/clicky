# vibe-id project template

Drop-in starter for a new product that uses [vibe-id](https://api.accounts.vibe-research.net) for sign-in, quotas, billing, and inference. Ship a project in 30 minutes; users get one account that works across every product you build.

## What you get

- **`swift/`** — Swift SDK (`VibeIdAccount.swift` + `VibeIdInstallTokenStore.swift`) for macOS apps. ~250 LOC total, single file each, no SPM dependencies.
- **`web/`** — JS SDK (`vibeid.js`) and a starter cross-project account page.

There's no worker template anymore. vibe-id serves `/chat`, `/tts`, and `/transcribe-token` directly — your project just points its client at `https://api.accounts.vibe-research.net` and passes its `project=X` parameter on sign-in. The install token is project-scoped at mint time, so vibe-id derives the project from the token alone on subsequent calls.

## Architecture

```
your app ── Bearer install_token ──►  api.accounts.vibe-research.net (vibe-id)
                                              │
                                              ▼
                                         Anthropic / ElevenLabs / AssemblyAI / etc.
```

vibe-id does auth + quota + upstream + record in a single round trip. You don't need to deploy any infra for a new project — just register the project row.

## Bootstrap a new project

### 1. Register the project in vibe-id (one row)

In the vibe-id worker dir:

```bash
npx wrangler d1 execute vibe-id --remote --command "
INSERT INTO projects (id, display_name, url_scheme, website_origin, created_at)
VALUES ('myproject', 'My Project', 'myproject', 'https://myproject.example', strftime('%s', 'now'));
"
```

If your project needs custom upstream endpoints (different model, different provider), also add `project_endpoints` rows — see `VIBE_ID_HANDOFF.md` for the schema.

### 2. Wire your client

**macOS / Swift** — copy `swift/VibeIdAccount.swift` and `swift/VibeIdInstallTokenStore.swift` into your project, then:

```swift
import Foundation

let account = VibeIdAccount(
    projectId: "myproject",
    vibeIdBaseURL: "https://api.accounts.vibe-research.net",
    appURLScheme: "myproject"
)

// Sign-in flow
account.signIn()

// In your AppDelegate:
func application(_ application: NSApplication, open urls: [URL]) {
    for url in urls {
        account.handleIncomingAuthURL(url)
    }
}

// On every authenticated request:
let token = VibeIdInstallTokenStore.currentInstallToken(forProjectId: "myproject")
request.setValue("Bearer \(token!)", forHTTPHeaderField: "Authorization")
// POST to https://api.accounts.vibe-research.net/chat (or /tts, /transcribe-token)
```

Plus add to `Info.plist`:
```xml
<key>CFBundleURLTypes</key>
<array>
    <dict>
        <key>CFBundleURLName</key>
        <string>com.yourcompany.myproject.auth</string>
        <key>CFBundleURLSchemes</key>
        <array>
            <string>myproject</string>
        </array>
    </dict>
</array>
```

**Web** — copy `web/vibeid.js`, then:

```html
<script src="vibeid.js"></script>
<script>
  VibeId.configure({
    projectId: "myproject",
    vibeIdBaseURL: "https://api.accounts.vibe-research.net",
  });
  VibeId.bootstrap().then((state) => {
    if (state.signedIn) renderSignedIn(state);
    else renderSignedOut();
  });
</script>
```

That's it. No worker deploy, no D1 of your own, no per-project Cloudflare zone.

## Forking — using your own auth instead

The contract any vibe-id-replacement must implement:

```
GET  /auth/start?project=X&device_id=Y&return_to=Z
     → 302 to OAuth → eventually 302 to <scheme>://auth?code=...

POST /auth/exchange { code, device_id, device_label }
     → { install_token, user, quotas, usage_today_by_project }

GET  /auth/me  Bearer install_token
     → { user, quotas, usage_today_by_project }

POST /auth/signout  Bearer install_token  → { ok: true }

POST /chat  Bearer install_token  → upstream chat response (streaming SSE)
POST /tts   Bearer install_token  → upstream TTS audio
POST /transcribe-token  Bearer install_token  → AssemblyAI session token
```

Implement those endpoints with your auth provider of choice and point the SDK's `vibeIdBaseURL` at it. No other changes needed.

## License

The template itself is MIT.
