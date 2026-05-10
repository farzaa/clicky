# Bootstrap Swarmlab

Step-by-step to take Swarmlab from "Coming soon" card to a real, signed-in, vibe-id-powered project. Now that vibe-id serves inference directly (no per-project worker), this is mostly D1 SQL + a website + an app.

Total time: maybe 15 minutes once vibe-id has the `projects` and `project_endpoints` tables.

## Prerequisites

- vibe-id deployed (already done — `api.accounts.vibe-research.net`).
- vibe-id has the `projects` table and validates `project=X` on `/auth/start` (this is what `VIBE_ID_HANDOFF.md` outlines — apply if not done yet).
- vibe-id has the `project_endpoints` table if you want Swarmlab to use a different upstream than Dot does. Otherwise it inherits the default endpoint config.

## 1. Register Swarmlab in vibe-id

In your vibe-id worker dir:

```bash
npx wrangler d1 execute vibe-id --remote --command "
INSERT INTO projects (id, display_name, url_scheme, website_origin, created_at)
VALUES ('swarmlab', 'Swarmlab', 'swarmlab', 'https://swarmlab.vibe-research.net', strftime('%s', 'now'));
"
```

Optional — per-project endpoint overrides. If Swarmlab uses the same chat/tts/transcribe-token endpoints as Dot, you don't need this. Add only if Swarmlab needs different upstreams (different model, different API):

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

Optional — per-project quota override. The `quotas` defaults are global; if Swarmlab should have different limits than Dot:

```bash
npx wrangler d1 execute vibe-id --remote --command "
INSERT INTO project_quotas (project_id, endpoint, daily_limit) VALUES
  ('swarmlab', 'chat', 100);
"
```

(Schema for `project_quotas` is in `BILLING_DESIGN.md` if you decide to add per-project quotas.)

## 2. Smoke-test that vibe-id recognizes Swarmlab

```bash
# Should redirect to Google with state including project=swarmlab
curl -sS -i "https://api.accounts.vibe-research.net/auth/start?project=swarmlab&device_id=test"

# After project validation lands (see VIBE_ID_HANDOFF.md), invalid project IDs should 400:
curl -sS -i "https://api.accounts.vibe-research.net/auth/start?project=fakeproject&device_id=test"
# expected: {"error":"unknown_project"}, status 400
```

## 3. Decide what Swarmlab IS

This template doesn't make a product decision for you. Some things Swarmlab could ship as:

- **Web app** — a multi-agent playground at swarmlab.vibe-research.net. Use `web/vibeid.js` from `vibe-id-project-template/`.
- **macOS app** — a desktop client like Dot but for orchestrating agents. Use `swift/VibeIdAccount.swift` and `swift/VibeIdInstallTokenStore.swift` from the template.
- **CLI** — a `swarmlab` command-line tool that authenticates once, then runs agent swarms. Same SDK pattern; just call `vibeIdBaseURL/auth/start` and store the token in `~/.config/swarmlab/`.

For anything that does real inference, the call pattern is:

```
POST https://api.accounts.vibe-research.net/chat
Authorization: Bearer <install_token>   // project-scoped at mint time
Body: { Anthropic Messages payload }
```

vibe-id derives `project=swarmlab` from the install token, applies Swarmlab's quota, charges Swarmlab's pricing if billing is on, records to Swarmlab in `usage_events`.

## 4. Build the website (if needed)

If you want swarmlab.vibe-research.net to serve a landing page:

```bash
mkdir -p ~/projects/swarmlab/web
# Author swarmlab.vibe-research.net/index.html — start by copying
# website/research-lab/index.html and replacing copy.

cd ~/projects/swarmlab/web
npx wrangler pages project create swarmlab-vibe-research --production-branch=main
npx wrangler pages deploy . --project-name=swarmlab-vibe-research --branch=main

# Custom domain
OAUTH_TOKEN=$(awk -F'"' '/oauth_token/ {print $2}' ~/Library/Preferences/.wrangler/config/default.toml)
curl -sS -X POST "https://api.cloudflare.com/client/v4/accounts/8ab237989bd3d7cc76bb4c53b5218c88/pages/projects/swarmlab-vibe-research/domains" \
  -H "Authorization: Bearer $OAUTH_TOKEN" \
  -H "Content-Type: application/json" \
  --data '{"name":"swarmlab.vibe-research.net"}'
```

The website calls vibe-id directly — no per-project Worker.

## 5. Flip the lab homepage

`vibe-research.net` shows Swarmlab as "Coming soon" because that's hardcoded in `website/research-lab/index.html`. To make the card a real link:

```html
<!-- replace the disabled card with: -->
<a class="project-card" href="https://swarmlab.vibe-research.net">
  <div class="project-name"><span class="project-marker-square"></span> Swarmlab <span class="project-arrow">↗</span></div>
  <p class="project-blurb">Multi-agent experiments — swarms of small models cooperating on real tasks.</p>
</a>
```

```bash
cd ~/projects/clicky/.claude/worktrees/.../website
npx wrangler pages deploy research-lab --project-name=vibe-research-root --branch=main
```

## What you don't have to do

- **No new Worker.** vibe-id is the only backend. Removing per-project workers cut the deploy surface in half.
- **No new D1 database.** Swarmlab's users, devices, usage events, balance — all in vibe-id's existing tables.
- **No new Google OAuth client, no new admin token.** vibe-id's existing setup handles every project.
- **No new DNS for an `api.swarmlab.vibe-research.net`.** It doesn't exist; Swarmlab's clients call `api.accounts.vibe-research.net` directly.

That's the payoff for collapsing dot-proxy into vibe-id.
