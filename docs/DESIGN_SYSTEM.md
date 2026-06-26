# Spider Design System

This is the product UI contract for Spider. The code source of truth is
`leanring-buddy/DesignSystem.swift`.

## Principles

- Native first: use SF Pro through SwiftUI system fonts.
- Quiet panel, clear action: the menu bar panel should feel compact, premium,
  glassy, rounded, and work-focused. No decorative gradients or loose marketing layout.
- Screen guidance is the product: visual emphasis belongs on the next action,
  active guidance, permissions, and campaign decision state.
- Do not invent per-screen spacing. Add or reuse tokens in `DS.SpiderPanel`.

## Typography

Use `DS.Typography`.

- `panelTitle`: 21 bold. Main screen titles.
- `panelHeader`: 20 bold. Compact wizard prompts.
- `cardTitle`: 17 bold. Card labels and field titles.
- `rowTitle`: 16 bold. List rows, settings rows, value rows.
- `rowBody`: 14 medium. Descriptions and row subtitles.
- `button`: 13 bold. Compact command buttons.
- `caption`: 12 medium. Helper text and footer labels.
- `micro`: 10 semibold. Section labels and small metadata.

The font family is SF Pro. Do not add a custom font unless the app has a real
brand need for it.

## Color

Use green-first tokens. The current product direction is green glass with soft
shadows and rounded corners. Do not add a second accent family.

- `chromeTint`: translucent green-black panel material.
- `accent`: Spider action green.
- `accentText`: dark text used on top of green actions.
- `primaryActionTint`: green glass tint for the primary card.
- `textPrimary`, `textMuted`, `textFaint`: text hierarchy.
- `divider`: low-contrast separators.
- `assetSurface`, `assetGlassTint`: default card glass.
- `secondaryControlSurface`, `secondaryControlTint`: secondary pills.
- `iconSurface`, `iconTint`: circular icon controls.

Shared app tokens under `DS.Colors` also use the same green accent family.
New work should not add raw accent colors inside views.

## Spacing

Use `DS.SpiderPanel.Layout` for the companion panel.

- Panel width: `360`
- Panel outer padding: `20`
- Default wizard stack spacing: `16`
- Compact section spacing: `14`
- Text stack spacing: `4`
- Card padding: `18`
- List horizontal padding: `18`
- Default list vertical padding: `4`
- Settings list vertical padding: `6`
- Campaign goal vertical padding: `10`
- Campaign goal row spacing: `2`
- Campaign goal row height: `62`

If one screen looks off, fix that screen with the closest existing token first.
Do not normalize unrelated screens just because the number appears nearby.

## Radius, Stroke, Shadow

Use:

- `DS.SpiderPanel.Radius.chrome`: panel shell, 30.
- `DS.SpiderPanel.Radius.card`: glass cards, 18.
- `DS.SpiderPanel.Stroke.hairline`: glass outlines, 0.8.
- `DS.SpiderPanel.Stroke.pill`: pill outlines, 0.6.
- `DS.SpiderPanel.Shadows.chromePrimary` and `chromeSecondary`: panel depth.
- `DS.SpiderPanel.Shadows.card`: standard card elevation.
- `DS.SpiderPanel.Shadows.primaryCard`: primary action card elevation.

## Component Rules

- The first row/header owns drag behavior. Do not make the whole panel draggable.
- Use glass cards for individual controls and repeated items only.
- Do not put cards inside cards.
- Primary actions use green glass pills with `accent` and `accentText`.
- Secondary actions use subdued glass surfaces.
- Keep campaign goal subtitles single-line unless the copy changes materially.
- Keep text sizing stable. No viewport-scaled fonts.

## Adding Tokens

Add a token when a value is reused, names a product-level decision, or prevents
layout drift. Do not add tokens for one-off geometry that is easier to read
inline.
