# AI Sensei 3000 Landing Page

This is a self-contained static landing page scaffold based on the ChatGPT Image 2 screenshot.

## Run locally

From the repository root:

```bash
python3 -m http.server 4173
```

Then open:

```text
http://127.0.0.1:4173/website/
```

## Asset slots

The page now uses the exported landing-page artwork under `website/assets/`. If you regenerate the slices, keep these filenames and overwrite the matching files.

Suggested filenames:

- `website/assets/logo/ai-sensei-3000-logo.png`
- `website/assets/characters/hero-teacher.png`
- `website/assets/characters/jade-card.png`
- `website/assets/characters/sakura-card.png`
- `website/assets/characters/teacher-card.png`
- `website/assets/characters/voice-mode.png`
- `website/assets/themes/sakura-theme-hero.png`
- `website/assets/themes/sakura-theme-1.png`
- `website/assets/themes/sakura-theme-2.png`
- `website/assets/themes/sakura-theme-3.png`

## Notes

- No build step is required.
- The page still references the repo logo from `../logo/` until the final logo is exported into `website/assets/logo/`.
- Once the logo is copied into `website/assets/`, this folder can be deployed independently.
