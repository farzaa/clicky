# Dot website

Two static sites live in this folder:

| Folder | Deploy to | Purpose |
|--------|-----------|---------|
| `dot/` | `dot.vibe-research.net` | Landing + sign-in + per-user account + admin dashboard for the Dot macOS app |
| `research-lab/` | `vibe-research.net` (root) | Minimal lab homepage that links to Swarmlab and Dot |

There's a third subdomain you'll set up yourself — `swarmlab.vibe-research.net` — by moving your existing vibe-research.net hosting there. That content isn't in this repo.

## DNS / Cloudflare setup

Assuming `vibe-research.net` is on Cloudflare (or you'll add it there):

1. Move your current `vibe-research.net` hosting to a new subdomain `swarmlab.vibe-research.net` (the bytes themselves stay where they are; just point a new CNAME at them).
2. Point `vibe-research.net` (root) at the new minimal page from `research-lab/`.
3. Point `dot.vibe-research.net` at the `dot/` static site.
4. Point `api.dot.vibe-research.net` at the Cloudflare Worker route (see `worker/README.md`).

## Deploying with Cloudflare Pages

Easiest option: two Pages projects, one per folder.

```bash
# Lab root
npx wrangler pages deploy website/research-lab \
  --project-name=vibe-research-root \
  --branch=main

# Dot site
npx wrangler pages deploy website/dot \
  --project-name=dot-vibe-research \
  --branch=main
```

Then in the Cloudflare dashboard, attach the right custom domain to each project.

## Before deploying the Dot site

Edit `website/dot/config.js` and replace:

- `workerBaseURL` — the Worker URL (e.g. `https://api.dot.vibe-research.net`).
- `downloadDmgURL` — the link to your latest macOS release DMG.
- `githubURL` — the public source repo URL.

## How sign-in works on the website

1. User clicks **Sign in with Google**. The button links to
   `<workerBaseURL>/auth/start?return_to=<websiteOrigin>/account.html`.
2. The Worker redirects to Google, then back to `/auth/callback`.
3. The Worker mints an install token, then redirects the browser to
   `<websiteOrigin>/account.html#token=<install_token>&email=<email>`.
4. `account.html` reads the URL fragment, stores the token in `localStorage`,
   strips the fragment from the address bar, then calls `/auth/me` with
   `Authorization: Bearer <token>` to populate today's usage.
5. **Sign out** posts to `/auth/signout` (revoking the device row server-side)
   and clears `localStorage`.

## Admin

`admin.html` is a one-page UI you reach by typing the URL directly — there's no
link from the rest of the site. Paste the value of the Worker secret
`DOT_ADMIN_TOKEN` into the input. The token is held in `sessionStorage` for
that browser tab only.

It calls two routes:
- `GET /admin/users` — list users with today's usage and limits.
- `GET /admin/usage` — last 30 days, bucketed by day + endpoint.

Both require `X-Admin-Token: <DOT_ADMIN_TOKEN>`.
