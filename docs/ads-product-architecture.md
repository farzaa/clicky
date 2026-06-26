# Spider Ads Product Architecture

Spider is pivoting from an app-building mentor into an independent paid ads
instructor and auditor, starting with Meta Ads.

Product thesis:

> Spider does not repeat Meta Ads. It audits ad platforms using official rules,
> independent playbooks, and the user's business context.

## MVP Scope

MVP v1 is Meta Ads first-step Guided Setup:

- turn the user's offer, audience, budget, and goal into a campaign direction;
- open Meta Ads from Spider;
- guide the visible setup screen one step at a time;
- stop before publishing, spend, billing, budget changes, pause, deletion, or
  any irreversible account action.

Preflight Audit and 72h Review are locked future features. They may remain in
the domain model and knowledge layer for later work, but the current MVP must
not present them as available actions.

V2 automates only the first-step Guided Setup loop. It should make the initial
setup guidance more continuous and less manual, not automate publishing or add
post-launch review.

Out of scope for v1:

- Google Ads, TikTok Ads, or X Ads execution.
- Meta API write access.
- Automatic publishing.
- Automatic budget edits.
- Automatic pausing or deletion.
- Ad account billing actions.
- ROAS, approval, or performance guarantees.
- Preflight Audit.
- 72h Review.
- A complex reporting dashboard.

## Safety Contract

Spider guides. The user clicks.

Spider must never:

- Publish an ad.
- Change budget.
- Edit billing.
- Delete campaigns.
- Pause campaigns automatically.
- Make irreversible ad account changes.
- Guarantee policy approval.
- Guarantee performance.

Human action is required before spend, publishing, billing, or any irreversible
campaign change.

The existing privacy boundary stays intact: the macOS app does not ship OpenAI
keys, the Worker owns AI calls, screenshots are not persisted, and analytics or
audit rows must not receive screenshots, prompts, model responses, campaign
content, sensitive metrics, personal data, emails, magic links, or session
tokens.

## Source Integrity & Decision Honesty

Spider doesn't repeat Meta. It audits ad platforms using official rules,
independent playbooks, and the user's business context.

O Spider não repete a Meta. Ele usa a Meta como fonte oficial e defende o
usuário com julgamento independente.

The Worker knowledge layer must keep source provenance explicit. Official Rules
come from versioned official sources in `worker/knowledge/source_registry.json`.
Official Definitions explain platform terms, but they do not decide strategy by
themselves. Official Guidance can inform the next step, but it still needs to be
crossed with the user's Ad Mission and visible screen context.

Spider Playbooks are independent operating judgment. They can recommend against
a platform option even when that option officially exists. They must never be
presented as Meta policy.

User Context personalizes the recommendation: offer, audience, budget, country,
language, landing page, business objective, prior decisions, and review timing.
The Decision Engine crosses Official Rules, Spider Playbooks, and User Context.
Decision Memory records the reasoning so the user does not repeat operational
mistakes.

Every audit response must preserve the visible split:

- `Official Rule`: official rule, definition, or guidance when an applicable
  source exists.
- `Spider Judgment`: independent recommendation applied to the user's business
  context.
- `Decision`: one fixed decision state.
- `Next Step`: the safest next manual action.

If an official source is absent, stale, marked `needs_review`, `outdated`, or
`deprecated`, Spider must be conservative and avoid pretending certainty.

## Product Layers

### Official Rules

Official platform material: policies, Help Center docs, platform definitions,
ad review behavior, sensitive categories, objectives, events, and limitations.

Official rules provide source-grounded truth. They do not make strategy
decisions by themselves.

### Operational Objects

Curated platform knowledge is converted into objects the product can apply:

- `PolicyRule`
- `PreflightCheck`
- `GuidedSetupStep`
- `RiskWarning`
- `CampaignObjective`
- `OptimizationDecision`
- `DecisionType`

Each object should include source metadata when it is grounded in an official
source: `platform`, `source_url`, `retrieved_at`, `topic`, `policy_area`, and
`status`.

### Independent Playbook

Spider's own judgment layer. This is where the product says things like:

- A Traffic objective is misaligned with a sales mission.
- Do not increase budget before there is enough signal.
- A low CTR points first at creative and offer framing, not at audience hacks.
- A no-conversion campaign may have a landing or tracking problem before it has
  a targeting problem.

The playbook must never pretend to be an official platform rule.

### User Context

The current Ad Mission:

- Offer.
- Audience.
- Ticket or price.
- Country and language.
- Budget.
- Business objective.
- Landing page.
- Recommended channel.
- Campaign plan.
- Decision memory.
- Review schedule.

The current screen is also context. If Spider cannot read the screen clearly, it
must say so and recommend a conservative next step.

### Decision Engine

The guide response must produce a structured decision:

- `safe_to_continue`
- `continue_with_warning`
- `fix_before_publish`
- `needs_more_signal`
- `do_not_publish`
- `manual_confirmation_required`

The response also includes `riskLevel`, `confidence`, `sourceType`,
`requiresManualConfirmation`, `reviewTrigger`, and a
`decisionMemoryUpdate` when there is durable operational reasoning to keep.

### Decision Memory

Spider records the reasoning, not just the campaign state.

Examples:

- Why Meta Ads was recommended.
- Why Traffic was rejected for a sales mission.
- Why budget was not increased.
- Why a creative was paused manually.
- Why a landing page needs work before the next test.
- When to review again.

Meta remembers campaign settings. Spider remembers operating judgment.

## Core Principle

Official rules never decide alone. Independent playbooks never pretend to be
official policy.

Meta may say an objective exists. Spider can say it exists and is still wrong
for this Ad Mission.
