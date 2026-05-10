# vibe-id changes needed for the multi-project story

The dot repo's `vibe-id-project-template/` is ready to be lifted into a separate `vibe-id-project-template` GitHub repo and used as a starting point for any new product. But three small changes have to land in the **vibe-id repo** (not this one) for the multi-project / open-source flow to be fully wired.

This file is the handoff. Apply each section in your vibe-id repo, then this dot repo and any future project repo can use the template as-is.

---

## 1. `projects` table — register each project + its URL scheme

**Why**: vibe-id's auth callback needs to know which `<scheme>://auth?code=…` URL to redirect to once Google OAuth completes. Today this is hardcoded. With a registry you add new projects (Swarmlab, future) by inserting a row instead of editing code.

**Schema**:

```sql
CREATE TABLE IF NOT EXISTS projects (
  id TEXT PRIMARY KEY,                    -- e.g. "dot", "swarmlab"
  display_name TEXT NOT NULL,             -- e.g. "Dot", "Swarmlab"
  url_scheme TEXT,                        -- e.g. "dot" — for native apps' <scheme>://auth handoff
  website_origin TEXT,                    -- e.g. "https://dot.vibe-research.net" — for return_to validation
  created_at INTEGER NOT NULL
);
```

**Migration** (existing dot row):

```sql
INSERT INTO projects (id, display_name, url_scheme, website_origin, created_at)
VALUES ('dot', 'Dot', 'dot', 'https://dot.vibe-research.net', strftime('%s', 'now'));
```

**Use in vibe-id's `/auth/start`**:

```ts
const project = await env.DB.prepare("SELECT * FROM projects WHERE id = ?").bind(projectId).first();
if (!project) return jsonResponse({ error: "unknown_project" }, 400);

// validate return_to (web flow) is on the project's registered website_origin
if (returnTo && new URL(returnTo).origin !== project.website_origin) {
  return jsonResponse({ error: "return_to_not_allowed" }, 400);
}
```

**Use in vibe-id's `/auth/callback`** — when minting the auth_code for an app sign-in:

```ts
const appRedirectUrl = new URL(`${project.url_scheme}://auth`);
appRedirectUrl.searchParams.set("code", authCode);
appRedirectUrl.searchParams.set("email", userRow.email);
return successHandoffResponse(appRedirectUrl.toString(), userRow.email);
```

---

## 2. `project_endpoints` table — per-project upstream routing

**Why**: vibe-id's `/v1/proxy/{endpoint}` currently hardcodes Anthropic for `chat`, ElevenLabs for `tts`, AssemblyAI for `transcribe-token`. To add a new project that uses, say, OpenAI for chat, or to add a new endpoint type like `image`, you'd be editing vibe-id source. Move the routing into a table.

**Schema**:

```sql
CREATE TABLE IF NOT EXISTS project_endpoints (
  project_id TEXT NOT NULL,
  endpoint TEXT NOT NULL,                 -- e.g. "chat", "tts", "transcribe-token", "image"
  upstream_url TEXT NOT NULL,             -- e.g. "https://api.anthropic.com/v1/messages"
  upstream_method TEXT NOT NULL DEFAULT 'POST',
  upstream_auth_header TEXT NOT NULL,     -- e.g. "x-api-key" or "authorization"
  upstream_auth_value_template TEXT NOT NULL, -- e.g. "{secret}" or "Bearer {secret}"
  upstream_secret_name TEXT NOT NULL,     -- name of the Worker secret holding the key
  upstream_extra_headers_json TEXT,       -- e.g. '{"anthropic-version":"2023-06-01"}'
  amount_kind TEXT NOT NULL,              -- "fixed" | "json_text_length" | "json_field"
  amount_value TEXT,                      -- "1" for fixed; "text" for json_text_length; etc.
  PRIMARY KEY (project_id, endpoint),
  FOREIGN KEY (project_id) REFERENCES projects(id)
);
```

**Migration** (existing dot endpoints):

```sql
INSERT INTO project_endpoints VALUES
  ('dot', 'chat',
   'https://api.anthropic.com/v1/messages', 'POST',
   'x-api-key', '{secret}',
   'ANTHROPIC_API_KEY',
   '{"anthropic-version":"2023-06-01"}',
   'fixed', '1'),

  ('dot', 'tts',
   'https://api.elevenlabs.io/v1/text-to-speech/kPzsL2i3teMYv0FxEYQ6', 'POST',
   'xi-api-key', '{secret}',
   'ELEVENLABS_API_KEY',
   '{"accept":"audio/mpeg"}',
   'json_text_length', 'text'),

  ('dot', 'transcribe-token',
   'https://streaming.assemblyai.com/v3/token?expires_in_seconds=480', 'GET',
   'authorization', '{secret}',
   'ASSEMBLYAI_API_KEY',
   NULL,
   'fixed', '1');
```

**Use in vibe-id's `/v1/proxy/{endpoint}` handler**:

```ts
async function handleProxyCall(request: Request, env: Env, endpoint: string): Promise<Response> {
  const projectId = request.headers.get("x-project");
  const internalKey = request.headers.get("x-internal-key");
  if (internalKey !== env.VIBE_ID_INTERNAL_KEY) return jsonResponse({ error: "unauthorized" }, 401);

  // 1. Auth + lookup user
  const installToken = readBearerToken(request);
  if (!installToken) return jsonResponse({ error: "missing_bearer_token" }, 401);
  const user = await lookupUserFromToken(env, installToken);
  if (!user) return jsonResponse({ error: "invalid_token" }, 401);

  // 2. Load endpoint config
  const endpointConfig = await env.DB.prepare(
    "SELECT * FROM project_endpoints WHERE project_id = ? AND endpoint = ?"
  ).bind(projectId, endpoint).first<ProjectEndpoint>();
  if (!endpointConfig) return jsonResponse({ error: "endpoint_not_configured" }, 404);

  // 3. Read body, compute amount for quota
  const requestBody = await request.text();
  const amount = computeAmount(endpointConfig.amount_kind, endpointConfig.amount_value, requestBody);

  // 4. Quota check
  const quotaCheck = await assertQuotaAvailable(env, user, endpoint, amount);
  if (!quotaCheck.ok) return quotaCheck.response;

  // 5. Build upstream request
  const upstreamSecret = await env[endpointConfig.upstream_secret_name as keyof Env];
  const upstreamHeaders: Record<string, string> = {
    [endpointConfig.upstream_auth_header]: endpointConfig.upstream_auth_value_template
      .replace("{secret}", upstreamSecret as string),
    "content-type": "application/json",
  };
  if (endpointConfig.upstream_extra_headers_json) {
    Object.assign(upstreamHeaders, JSON.parse(endpointConfig.upstream_extra_headers_json));
  }

  // 6. Forward
  const upstreamResponse = await fetch(endpointConfig.upstream_url, {
    method: endpointConfig.upstream_method,
    headers: upstreamHeaders,
    body: endpointConfig.upstream_method === "GET" ? undefined : requestBody,
  });

  // 7. Record usage (don't await — let it run in waitUntil)
  ctx.waitUntil(recordUsageEvent(env, user.id, projectId, endpoint, amount, upstreamResponse.status));

  return new Response(upstreamResponse.body, {
    status: upstreamResponse.status,
    headers: { "content-type": upstreamResponse.headers.get("content-type") ?? "application/json" },
  });
}

function computeAmount(kind: string, value: string | null, body: string): number {
  switch (kind) {
    case "fixed": return parseInt(value ?? "1", 10);
    case "json_text_length": {
      try {
        const parsed = JSON.parse(body) as Record<string, unknown>;
        const fieldValue = parsed[value ?? "text"];
        return typeof fieldValue === "string" ? fieldValue.length : 0;
      } catch { return 0; }
    }
    case "json_field": {
      try {
        const parsed = JSON.parse(body) as Record<string, unknown>;
        const fieldValue = parsed[value ?? "amount"];
        return typeof fieldValue === "number" ? fieldValue : 0;
      } catch { return 0; }
    }
    default: return 1;
  }
}
```

After this is in place, **adding a new project** = (a) one row in `projects`, (b) N rows in `project_endpoints` (one per upstream you proxy), (c) per-project secrets via `wrangler secret put`. **Adding a new endpoint type** to an existing project = one row in `project_endpoints`. Zero code changes either way.

---

## 3. `/auth/me` already returns the right shape — just verify

The cross-project account dashboard (in `vibe-id-project-template/web/account.html` and updated in this repo's `website/dot/account.html` once the dot repo's sandbox loosens) expects:

```ts
GET /auth/me  Authorization: Bearer <install_token>
→ {
    user: { id, email, display_name, picture_url },
    quotas: { chat: 200, tts: 50000, "transcribe-token": 100, ... },
    usage_today_by_project: {
      "dot":      { chat: 5, tts: 412 },
      "swarmlab": { chat: 1 }
    }
  }
```

The Mark-side merge already moved to this shape. Just verify it returns ALL projects the user has touched (not just the project that issued the install token), so the dashboard shows everything in one place.

---

## 4. Optional: per-project quotas

Right now `quotas` is a flat per-user map (`chat → 200`). Means a user gets 200 chats split across all projects, not 200 per project. That may or may not be what you want. If you want per-project quotas:

```sql
ALTER TABLE quotas ADD COLUMN project_id TEXT;
-- backfill existing rows with NULL project_id meaning "applies to all projects"
-- new rows can scope to a single project
```

Plus: `assertQuotaAvailable` checks the more specific (user, project, endpoint) row first, falls back to (user, endpoint) row if no project-specific row exists.

---

## 5. The five-endpoint contract for forks

If anyone wants to swap vibe-id for their own auth provider (the "fork" story), document this contract in vibe-id's README:

```
GET  /auth/start?project=X&device_id=Y&return_to=Z
     → 302 to OAuth → eventually 302 to <scheme>://auth?code=...

POST /auth/exchange { code, device_id, device_label }
     → { install_token, user, quotas }

GET  /auth/me  Authorization: Bearer <install_token>
     → { user, quotas, usage_today_by_project }

POST /auth/signout  Authorization: Bearer <install_token>
     → { ok: true }

POST /v1/proxy/{endpoint}
     Headers: Authorization: Bearer <install_token>
              x-internal-key: <shared_secret>
              x-project: X
     Body: passthrough to upstream
     → upstream response (status passed through)
```

Anyone implementing those five endpoints can drop their service URL into `vibeIdBaseURL` (web) / `VibeIdBaseURL` plist key (macOS) and the rest of the project keeps working.

---

## Order of operations

1. Apply (1) and (2) schema migrations to vibe-id's D1.
2. Update `/auth/callback` and `/v1/proxy/*` handlers in vibe-id.
3. Insert the `dot` project rows from the migration SQL above.
4. Deploy vibe-id, smoke-test the sign-in flow on dot.
5. (Optional) Once it's stable, add per-project quotas.
6. Document the fork contract in vibe-id's README.

After step 4, this dot repo and any new repo cloned from `vibe-id-project-template/` should Just Work without any further changes here.
