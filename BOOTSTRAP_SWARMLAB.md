# Bootstrap Swarmlab from the vibe-id project template

Step-by-step to take Swarmlab from "card on the lab homepage" to a real, signed-in, vibe-id-powered project. Total time: maybe 20 minutes once `VIBE_ID_HANDOFF.md` is applied to your vibe-id repo.

## Prerequisites

- `VIBE_ID_HANDOFF.md` migrations applied to vibe-id (the `projects` and `project_endpoints` tables, the `/v1/proxy/{endpoint}` dispatcher). **Without this, vibe-id won't recognize `project=swarmlab` and sign-in will issue tokens with no defined upstreams.**
- vibe-research.net zone on Cloudflare (already done — that's how api.dot.vibe-research.net works).
- A new GitHub repo for Swarmlab source.

## 1. Register the project in vibe-id (SQL)

In your vibe-id worker dir:

```bash
npx wrangler d1 execute vibe-id --remote --command "
INSERT INTO projects (id, display_name, url_scheme, website_origin, created_at)
VALUES ('swarmlab', 'Swarmlab', 'swarmlab', 'https://swarmlab.vibe-research.net', strftime('%s', 'now'));
"
```

Add the upstream endpoints Swarmlab will need. Swap in whichever upstream APIs you actually want — the example below assumes Anthropic for chat-style multi-agent calls:

```bash
npx wrangler d1 execute vibe-id --remote --command "
INSERT INTO project_endpoints VALUES
  ('swarmlab', 'chat',
   'https://api.anthropic.com/v1/messages', 'POST',
   'x-api-key', '{secret}',
   'ANTHROPIC_API_KEY',
   '{\"anthropic-version\":\"2023-06-01\"}',
   'fixed', '1');
"
```

Per-user quota for swarmlab — start conservative, raise later:

```bash
npx wrangler d1 execute vibe-id --remote --command "
-- per-endpoint daily limit applied to all users on this project. If you
-- want different limits per project, the schema in HANDOFF.md supports
-- that with project_id NULL = applies-to-all fallback.
INSERT INTO default_quotas (project_id, endpoint, daily_limit) VALUES
  ('swarmlab', 'chat', 100);
"
```

## 2. Bootstrap the project repo from the template

```bash
# Outside this dot repo:
cd ~/projects
cp -r ~/projects/clicky/.claude/worktrees/.../vibe-id-project-template swarmlab
cd swarmlab

git init
gh repo create Clamepending/swarmlab --public --source=. --remote=origin
```

(Alternatively, fork `Clamepending/dot` and strip out the macOS app + Dot-specific code, keeping just the worker + SDK + website skeleton. The template path is cleaner.)

## 3. Replace placeholders in the template

In `worker/src/index.ts`:
- `const PROJECT_ID = "myproject";` → `const PROJECT_ID = "swarmlab";`
- `SUPPORTED_ENDPOINTS` — should match the rows you inserted in step 1.

In `worker/wrangler.toml`:
- `name = "myproject-proxy"` → `name = "swarmlab-proxy"`
- `routes = [{ pattern = "api.myproject..." }]` → `pattern = "api.swarmlab.vibe-research.net"`

In `web/account.html` and `web/vibeid.js` (if you wire a website):
- `projectId: "myproject"` → `projectId: "swarmlab"`

In `swift/VibeIdAccount.swift` callers (if you ship a macOS app):
- Pass `projectId: "swarmlab"`, `appURLScheme: "swarmlab"`.
- Add `swarmlab://` to `Info.plist` `CFBundleURLTypes`.

## 4. Deploy the worker

```bash
cd worker
npm install
npx wrangler secret put VIBE_ID_INTERNAL_KEY   # paste the same value as vibe-id's
npx wrangler deploy
```

This provisions the custom domain `api.swarmlab.vibe-research.net` and the Service Binding to vibe-id automatically (the binding only needs both workers to be in the same Cloudflare account, which they are).

## 5. Deploy the website (optional — only if Swarmlab has web UI)

If you want a swarmlab.vibe-research.net landing page:

```bash
cd ~/projects/swarmlab/web
npx wrangler pages project create swarmlab-vibe-research --production-branch=main
npx wrangler pages deploy . --project-name=swarmlab-vibe-research --branch=main

# Custom domain via API (Cloudflare's wrangler doesn't expose a CLI command for this):
OAUTH_TOKEN=$(awk -F'"' '/oauth_token/ {print $2}' ~/Library/Preferences/.wrangler/config/default.toml)
curl -sS -X POST "https://api.cloudflare.com/client/v4/accounts/8ab237989bd3d7cc76bb4c53b5218c88/pages/projects/swarmlab-vibe-research/domains" \
  -H "Authorization: Bearer $OAUTH_TOKEN" \
  -H "Content-Type: application/json" \
  --data '{"name":"swarmlab.vibe-research.net"}'
```

You'll likely also need to add a CNAME `swarmlab` → `swarmlab-vibe-research.pages.dev` in the Cloudflare DNS dashboard (Cloudflare's Pages-API doesn't always auto-create the CNAME; we hit this with dot.vibe-research.net too).

## 6. Smoke-test the auth flow

```bash
# Should return {"ok":true,"project":"swarmlab"}
curl -sS https://api.swarmlab.vibe-research.net/health

# Should redirect to Google OAuth with project=swarmlab in state
curl -sS -i "https://api.accounts.vibe-research.net/auth/start?project=swarmlab&device_id=test"

# Should reject (no bearer)
curl -sS -X POST -d '{}' https://api.swarmlab.vibe-research.net/chat
```

If the first call returns `{"error":"unknown_project"}`, the SQL in step 1 didn't apply (or your handoff migration isn't deployed yet). If it returns `{"error":"endpoint_not_configured"}`, step 1's INSERT INTO project_endpoints didn't run.

## 7. Open the lab homepage

`vibe-research.net` will still show Swarmlab as "Coming soon" because that label is hardcoded in `website/research-lab/index.html` from the dot repo. To flip it to active:

```html
<!-- replace the disabled card with: -->
<a class="project-card" href="https://swarmlab.vibe-research.net">
  <div class="project-name"><span class="project-marker-square"></span> Swarmlab <span class="project-arrow">↗</span></div>
  <p class="project-blurb">Multi-agent experiments — swarms of small models cooperating on real tasks.</p>
</a>
```

Then:
```bash
cd ~/projects/clicky/.claude/worktrees/.../website
npx wrangler pages deploy research-lab --project-name=vibe-research-root --branch=main
```

## What you DON'T need to do

- No new D1 database, no new auth code, no new admin dashboard. Swarmlab uses vibe-id's `users`, `devices`, `usage_events` tables. Sign-ins, quota checks, usage records, admin views — all shared across every project.
- No new Google OAuth client or new `wrangler secret put GOOGLE_OAUTH_CLIENT_*`. vibe-id's existing client handles every project.
- No per-project secrets beyond `VIBE_ID_INTERNAL_KEY` (which is the same value everywhere).

That's the payoff for the multi-project architecture.
