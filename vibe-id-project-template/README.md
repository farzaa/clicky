# vibe-id project template

Drop-in starter for a new product that uses [vibe-id](https://api.accounts.vibe-research.net) for sign-in, quotas, billing, and inference. Ship a project in 30 minutes; users get one account that works across every product you build.

## What you get

- **`worker/`** — A 75-line Cloudflare Worker that forwards `/chat`, `/tts`, `/transcribe-token` to vibe-id's `/v1/proxy/*` endpoints. Holds zero secrets beyond a shared internal key.
- **`swift/`** — A Swift SDK (`VibeIdAccount.swift` + `VibeIdInstallTokenStore.swift`) for macOS apps. ~250 LOC total, single file each, no SPM dependencies.
- **`web/`** — A JS SDK (`vibeid.js`) and a starter account page that anyone signed in to vibe-id can use across all your projects.

## Architecture

```
your app  ─── Bearer install_token ───►  api.<project>.<your domain>
                                              │ env.VIBE_ID.fetch
                                              │ (in-process, ~0ms)
                                              ▼
                                         api.accounts.vibe-research.net (vibe-id)
                                              │
                                              ▼
                                         Anthropic / ElevenLabs / DALL-E / etc.
```

Your worker is stateless and 75 LOC. All upstream API keys, user accounts, OAuth, quotas, and usage data live on vibe-id. To add a new endpoint type, you register it in vibe-id's `project_endpoints` table — no code change to your worker.

## Bootstrap a new project

### 1. Register the project in vibe-id (one row)

```sql
INSERT INTO projects (id, display_name, url_scheme) VALUES
  ('myproject', 'My Project', 'myproject');

INSERT INTO project_endpoints (project_id, endpoint, upstream_url, upstream_secret_name, amount_extractor) VALUES
  ('myproject', 'chat',             'https://api.anthropic.com/v1/messages',                'ANTHROPIC_API_KEY',  'fixed:1'),
  ('myproject', 'tts',              'https://api.elevenlabs.io/v1/text-to-speech/{voice}',  'ELEVENLABS_API_KEY', 'json:text.length'),
  ('myproject', 'transcribe-token', 'https://streaming.assemblyai.com/v3/token',            'ASSEMBLYAI_API_KEY', 'fixed:1');
```

Then set per-user defaults in `quotas` (or rely on the global default).

### 2. Copy this template

```bash
cp -r vibe-id-project-template ~/projects/my-new-project
cd ~/projects/my-new-project
```

### 3. Replace placeholders

In `worker/wrangler.toml`:
- `name = "myproject-proxy"`
- `routes` → `api.myproject.<your-domain>`

In `swift/VibeIdAccount.swift`:
- The `init` takes `projectId` and `urlScheme` — pass `"myproject"` and `"myproject"` from your app.

In `web/vibeid.js`:
- The default config object's `projectId`.

### 4. Deploy

```bash
cd worker
npx wrangler secret put VIBE_ID_INTERNAL_KEY  # share with vibe-id
npx wrangler deploy
```

### 5. Wire your app

**macOS / Swift:**

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

**Web:**

```html
<script src="vibeid.js"></script>
<script>
  VibeId.configure({ projectId: "myproject" });
  document.getElementById("signin").onclick = () => VibeId.signIn();
  VibeId.onSignedIn((user) => console.log("hello", user.email));
</script>
```

## Forking — using your own auth instead

The contract any vibe-id-replacement must implement:

```
GET  /auth/start?project=X&device_id=Y&return_to=Z   → 302 to OAuth, eventually 302 to <scheme>://auth?code=...
POST /auth/exchange { code, device_id, device_label } → { install_token, user, quotas, usage_today_by_project }
GET  /auth/me  Bearer install_token                  → { user, quotas, usage_today_by_project }
POST /auth/signout  Bearer install_token             → { ok: true }
POST /v1/proxy/{endpoint}  Bearer + x-internal-key + x-project + body  → upstream response
```

Implement those five endpoints with your auth provider of choice and point the SDK's `vibeIdBaseURL` at it. No other changes needed.

## License

Pick whatever fits your project. The template itself is MIT.
