# Spider Apple Developer Program Runbook

This document defines how Spider should use `guia_app_store_connect_ai_po_denso.pdf` to guide a user through Apple Developer Program, Certificates, Identifiers & Profiles, Xcode signing, App Store Connect, TestFlight, App Review, agreements, tax, banking, IAP, and subscriptions.

The PDF is not a runtime guide by itself. It is the conceptual source material. Spider needs task runbooks: screen-aware, click-aware, field-aware flows that give one safe next action at a time.

## Product Goal

Spider should behave like a screen-first Apple distribution mentor for non-technical founders. It should look at the user's current screen, identify the workflow stage, point to the next control when possible, explain the field only as much as needed, and stop before irreversible or sensitive actions.

Good Spider guidance:

> Click `Identifiers` in the left sidebar, then click the `+` button. We are creating the technical identity that must match your Xcode Bundle Identifier.

Bad Spider guidance:

> You need an App ID, a provisioning profile, signing, capabilities, and App Store Connect metadata.

The second answer is true and useless. Users do not need a lecture while staring at Apple's UI. They need the next move.

## Source Document Usage

Use the PDF as the base taxonomy and safety policy:

- Apple Developer vs App Store Connect vs Xcode vs TestFlight.
- Bundle ID, App ID, capabilities, certificates, provisioning profiles, signing.
- App record, metadata, screenshots, privacy labels, age rating, build selection, App Review.
- Agreements, paid apps, banking, tax, IAP, subscriptions.
- Security boundaries around credentials, 2FA, banking, tax, secrets, and private keys.
- Diagnostic patterns: missing build, wrong Bundle ID, invalid binary, contract missing, privacy mismatch, review unable to log in.

Do not use the PDF as a frozen source of truth for interface labels or policy details. Apple changes names, screen positions, country rules, pricing, contracts, and review requirements. For production guidance, any high-risk or drift-prone topic must be checked against official Apple documentation before being treated as current.

High-risk topics:

- enrollment requirements;
- individual vs organization account;
- D-U-N-S and legal entity verification;
- roles and permissions;
- certificates, profiles, keys, and capabilities;
- paid app agreements;
- tax and banking;
- IAP and subscriptions;
- app privacy labels;
- App Review and regional compliance;
- export compliance and encryption;
- EU or alternative marketplace distribution.

## Runtime Contract

Spider must produce one concrete next action, not a full tutorial dump.

Each response should contain:

- `screen_stage`: what Spider believes the user is looking at.
- `confidence`: high, medium, or low.
- `next_click`: exact visible label or approximate UI target.
- `why`: one short reason the action matters.
- `fill_value`: only when the value is known or safely derivable.
- `ask_for`: only when Spider cannot safely infer a value.
- `validation`: how the user can tell the step worked.
- `stop_condition`: what would make Spider pause.
- `security_boundary`: sensitive data Spider must not collect.

Example response shape:

```json
{
  "screen_stage": "apple_developer_identifiers_list",
  "confidence": "high",
  "next_click": "Click the + button near Identifiers",
  "why": "We need to create the App ID that will own this app's Bundle ID and capabilities.",
  "fill_value": null,
  "ask_for": null,
  "validation": "The next screen should show identifier type options such as App IDs.",
  "stop_condition": "If you do not see Identifiers, you may not have Account Holder/Admin access.",
  "security_boundary": "Do not ask for Apple password or 2FA code."
}
```

## Screen Domains

Spider should classify Apple distribution screens into these domains before answering:

| Domain | Examples | Primary risk |
| --- | --- | --- |
| `apple_developer_membership` | enrollment, renewal, D-U-N-S, identity verification | legal/account decisions |
| `apple_developer_access` | roles, users, team membership | wrong user permissions |
| `apple_developer_identifiers` | App IDs, Bundle IDs, Services IDs, app groups | build cannot attach to app |
| `apple_developer_capabilities` | Push, Sign in with Apple, Associated Domains, iCloud | entitlements mismatch |
| `apple_developer_certificates` | certificate request, download, revoke | private key/account damage |
| `apple_developer_profiles` | development, ad hoc, App Store Connect profiles | signing failure |
| `xcode_signing` | Signing & Capabilities, archive, upload | wrong team or Bundle ID |
| `app_store_connect_app_record` | New App, SKU, platform, primary language | app record bound to wrong identifier |
| `app_store_connect_metadata` | description, keywords, support URL, screenshots | review/metadata rejection |
| `app_store_connect_privacy` | app privacy labels, SDK data mapping | user data misrepresentation |
| `app_store_connect_testflight` | builds, internal testing, external groups | untested build or missing compliance |
| `app_store_connect_review` | build selection, review notes, submission | reviewer cannot test |
| `app_store_connect_business` | agreements, banking, tax, paid apps | sensitive financial data |
| `app_store_connect_iap` | products, subscriptions, sandbox testers | broken purchase flow |

If Spider cannot classify the screen, it should ask for one visible heading or button. It should not invent a route.

## Security Rules

Security beats convenience. This product watches screens. That is powerful and dangerous if handled like a toy.

Spider must never ask the user to paste or say:

- Apple Account password;
- 2FA code;
- full banking details;
- full tax forms;
- private keys;
- `.p8`, `.p12`, `.cer`, provisioning profiles, or certificate signing material unless the task explicitly requires local file handling and the file never leaves the user's machine;
- App Store Connect API private key;
- Stripe, OpenAI, Resend, Cloudflare, Firebase, Supabase, or other secrets;
- screenshots containing real customer data, bank data, tax identifiers, or production credentials.

Spider may guide the user to fill sensitive forms inside Apple's UI, but the values must stay between the user and Apple.

Allowed:

> Click `Business`, open `Agreements`, and fill your banking information directly on Apple's page. I do not need to see the bank fields.

Not allowed:

> Send me the account number and routing number so I can tell you what to enter.

## Guidance Style

Spider should be operational, not academic.

Use:

- short next-step instructions;
- plain names from the visible UI;
- one sentence explaining impact;
- warning only when risk is real;
- confirmation before irreversible actions.

Avoid:

- dumping the whole Apple workflow;
- explaining every possible exception;
- telling the user to upload another build before checking Bundle ID, processing status, or ITMS errors;
- saying "does not collect data" without auditing SDKs and backend flows;
- making legal, tax, or privacy claims as if Spider were counsel.

## Runbook Schema

Each Apple workflow should be converted into this structure:

```yaml
id: stable_snake_case_task_id
domain: apple_developer_identifiers
goal: What the user is trying to complete
entry_signals:
  - Visible heading or button text
  - User phrase
  - Detected URL pattern if available
required_role:
  - Account Holder
  - Admin
preflight_questions:
  - Ask only what changes the next action
steps:
  - screen: expected screen or state
    instruction: one concrete action
    click_target: visible label or target description
    field: field name if filling a value
    value_rule: exact accepted format or derivation rule
    explain: why this matters in one sentence
    validation: what success looks like
    stop_if: condition that should pause guidance
security:
  never_collect:
    - sensitive item
official_sources:
  - Apple docs URL
last_verified: YYYY-MM-DD
```

The `last_verified` field matters. Apple docs are not stone tablets; they are wet cement.

## Core Runbooks

### 1. Enroll In Apple Developer Program

```yaml
id: enroll_apple_developer_program
domain: apple_developer_membership
goal: Enroll the user or their organization in Apple Developer Program.
entry_signals:
  - "Join the Apple Developer Program"
  - "Enrollment"
  - "Apple Developer app"
  - User says "I need to publish my app"
required_role:
  - Individual owner or organization-authorized person
preflight_questions:
  - "Will the seller name be your personal legal name or a company legal name?"
steps:
  - screen: Apple Developer Program landing or account membership page
    instruction: Click the enrollment option for Apple Developer Program.
    click_target: "Enroll" or "Start Your Enrollment"
    explain: Publishing to the App Store requires Developer Program membership; a free Apple Account is not enough for distribution.
    validation: The page asks for individual or organization enrollment details.
    stop_if: The user is trying to enroll a company but does not have legal authority.
  - screen: enrollment account requirements
    instruction: Confirm two-factor authentication is enabled on the Apple Account.
    click_target: visible 2FA/account prompt
    explain: Apple requires 2FA for enrollment.
    validation: The enrollment flow lets the user continue.
    stop_if: Spider is asked for a password or 2FA code.
  - screen: organization enrollment details
    instruction: Enter the legal entity name, D-U-N-S number, work email, and public company website directly in Apple's form.
    click_target: visible form fields
    explain: Organization enrollment controls the seller name shown on the App Store.
    validation: Apple accepts the organization details or asks for additional verification.
    stop_if: The user wants to use a trade name, DBA, social profile, or placeholder site as the legal identity.
security:
  never_collect:
    - Apple password
    - 2FA code
    - government ID image
    - full legal documents
official_sources:
  - https://developer.apple.com/help/account/membership/program-enrollment
last_verified: 2026-06-17
```

### 2. Register Explicit App ID And Bundle ID

```yaml
id: register_explicit_app_id_bundle_id
domain: apple_developer_identifiers
goal: Create the App ID that matches the Xcode target Bundle Identifier.
entry_signals:
  - "Certificates, Identifiers & Profiles"
  - "Identifiers"
  - "Register an App ID"
  - User says "which Bundle ID should I use?"
required_role:
  - Account Holder
  - Admin
preflight_questions:
  - "What Bundle Identifier appears in Xcode under Signing & Capabilities?"
steps:
  - screen: Certificates, Identifiers & Profiles
    instruction: Click `Identifiers` in the sidebar, then click the `+` button.
    click_target: "Identifiers", then "+"
    explain: The App ID is the Apple-side identity that must match the app's Bundle Identifier.
    validation: The identifier type list appears.
    stop_if: Identifiers is missing, because the user may not have the right role.
  - screen: identifier type
    instruction: Select `App IDs`, then continue.
    click_target: "App IDs"
    explain: We are creating an app identity, not a Services ID or app group.
    validation: The App ID type screen appears.
    stop_if: The user is configuring web Sign in with Apple only; that may require a Services ID instead.
  - screen: App ID form
    instruction: Select `Explicit App ID`, then enter the exact Bundle ID from Xcode.
    click_target: "Explicit App ID"
    field: "Bundle ID"
    value_rule: Reverse-DNS string, lowercase, no spaces, exact match with Xcode target.
    explain: If this value differs by one character, uploaded builds may not appear under the expected app.
    validation: Apple lets the user continue to capabilities/review.
    stop_if: The user wants a wildcard App ID for an App Store app with capabilities.
  - screen: capabilities
    instruction: Select only the capabilities the app actually uses.
    click_target: capability checkboxes
    explain: Capabilities become entitlement expectations; random checkboxes create signing and review mess.
    validation: The review screen lists the Bundle ID and selected capabilities.
    stop_if: The user is unsure about push, iCloud, Associated Domains, or Sign in with Apple; check the Xcode target first.
security:
  never_collect:
    - Apple password
    - 2FA code
    - private keys
official_sources:
  - https://developer.apple.com/help/account/identifiers/register-an-app-id
last_verified: 2026-06-17
```

### 3. Enable Or Adjust Capabilities

```yaml
id: enable_app_id_capabilities
domain: apple_developer_capabilities
goal: Align Apple Developer capabilities with the Xcode target entitlements.
entry_signals:
  - "Edit your App ID Configuration"
  - "Capabilities"
  - User says "push notifications are not working"
  - User says "Sign in with Apple"
required_role:
  - Account Holder
  - Admin
preflight_questions:
  - "Which capability did you add in Xcode?"
steps:
  - screen: Identifiers list
    instruction: Open the App ID whose Bundle ID matches the Xcode target.
    click_target: matching Bundle ID row
    explain: Capabilities must be attached to the same identifier used by the app binary.
    validation: The App ID detail page appears with capabilities.
    stop_if: More than one similar Bundle ID exists; compare exact strings before clicking.
  - screen: App ID detail
    instruction: Enable the matching capability and follow any configuration prompt.
    click_target: capability checkbox or configuration button
    explain: The Apple-side capability must match the entitlement Xcode signs into the app.
    validation: The capability is checked and saved.
    stop_if: Apple shows a warning that the capability requires explicit App ID, extra setup, or a separate key.
security:
  never_collect:
    - private keys
    - APNs auth key
    - service key files
official_sources:
  - https://developer.apple.com/help/account/identifiers/register-an-app-id
last_verified: 2026-06-17
```

### 4. Use Automatic Signing Before Manual Profiles

```yaml
id: prefer_xcode_automatic_signing
domain: xcode_signing
goal: Keep beginners on Xcode automatic signing unless manual signing is truly required.
entry_signals:
  - "Signing & Capabilities"
  - "Automatically manage signing"
  - "No profiles for"
  - User says "provisioning profile error"
required_role:
  - Developer account access in Xcode
preflight_questions:
  - "Is `Automatically manage signing` checked?"
steps:
  - screen: Xcode Signing & Capabilities
    instruction: Select the correct development team and keep `Automatically manage signing` enabled.
    click_target: "Team" dropdown and "Automatically manage signing"
    explain: For most first-app workflows, Xcode should manage profiles instead of making the user juggle certificates manually.
    validation: Xcode stops showing signing errors or creates profiles automatically.
    stop_if: The team uses CI/CD, enterprise signing, or a centralized certificate policy.
  - screen: persistent signing error
    instruction: Compare the Xcode Bundle Identifier with the Apple Developer App ID and App Store Connect app record.
    click_target: Bundle Identifier field
    explain: Most "profile" errors are actually identity mismatch wearing a fake mustache.
    validation: Bundle ID matches across Xcode, Apple Developer, and App Store Connect.
    stop_if: The error mentions a missing capability; check App ID capabilities before changing profiles.
security:
  never_collect:
    - signing certificates
    - private keys
    - Apple Account credentials
official_sources:
  - https://developer.apple.com/help/account/provisioning-profiles/create-a-development-provisioning-profile
  - https://developer.apple.com/help/account/provisioning-profiles/create-an-app-store-provisioning-profile
last_verified: 2026-06-17
```

### 5. Create App Store Connect App Record

```yaml
id: create_app_store_connect_app_record
domain: app_store_connect_app_record
goal: Create the product record that receives builds and metadata.
entry_signals:
  - "Apps"
  - "New App"
  - "Prepare for Submission"
required_role:
  - Account Holder
  - Admin
  - App Manager
preflight_questions:
  - "Does the Bundle ID already exist in Apple Developer and match Xcode?"
steps:
  - screen: App Store Connect Apps list
    instruction: Click the `+` button and choose `New App`.
    click_target: "+", then "New App"
    explain: The app record is the store product page; it is not the build.
    validation: The New App dialog appears.
    stop_if: Apple says the latest agreement must be signed first.
  - screen: New App dialog
    instruction: Select only the platform the current binary supports.
    click_target: platform checkboxes
    explain: Extra platforms create extra metadata and review obligations.
    validation: The selected platform matches the Xcode target.
    stop_if: The user marks every platform "just in case".
  - screen: New App dialog
    instruction: Fill name, primary language, Bundle ID, SKU, and access.
    click_target: visible fields
    value_rule: Bundle ID must match Xcode; SKU is internal, unique, no spaces or sensitive data.
    explain: The Bundle ID binds this store record to uploaded builds.
    validation: App Store Connect creates the record with `Prepare for Submission`.
    stop_if: The desired name, SKU, or Bundle ID is already used.
security:
  never_collect:
    - Apple password
    - 2FA code
official_sources:
  - https://developer.apple.com/help/app-store-connect/create-an-app-record/add-a-new-app
last_verified: 2026-06-17
```

### 6. Sign Paid Apps Agreement

```yaml
id: sign_paid_apps_agreement
domain: app_store_connect_business
goal: Unlock paid apps, IAP, and subscriptions before monetization work.
entry_signals:
  - "Business"
  - "Agreements"
  - "Paid Apps"
  - User says "IAP not available"
  - User says "subscription cannot be submitted"
required_role:
  - Account Holder
preflight_questions:
  - "Will the app sell paid downloads, IAP, or subscriptions?"
steps:
  - screen: App Store Connect top navigation
    instruction: Click `Business`, then open the `Agreements` tab.
    click_target: "Business", then "Agreements"
    explain: Paid apps and in-app purchases require a paid agreement before the store can sell anything.
    validation: The agreements list shows a Paid Apps row.
    stop_if: The user is not the Account Holder.
  - screen: Paid Apps agreement row
    instruction: Click `View and Agree to Terms`, read the agreement, and accept only if the Account Holder is ready.
    click_target: "View and Agree to Terms"
    explain: Accepting this is a legal action and Apple says it cannot be undone.
    validation: The Paid Apps agreement status changes from action required to active or pending setup.
    stop_if: The user asks Spider to accept terms for them.
security:
  never_collect:
    - 2FA code
    - banking details
    - tax identifiers
    - legal documents
official_sources:
  - https://developer.apple.com/help/app-store-connect/manage-agreements/sign-and-update-agreements
last_verified: 2026-06-17
```

### 7. Complete Banking And Tax Setup

```yaml
id: complete_banking_tax_setup
domain: app_store_connect_business
goal: Help the user find and complete banking/tax setup without exposing sensitive data to Spider.
entry_signals:
  - "Banking"
  - "Tax"
  - "Business"
  - "Payments"
  - User says "Apple is asking for bank/tax"
required_role:
  - Account Holder
  - Finance where Apple permits the task
preflight_questions:
  - "Are you the person authorized to enter company financial and tax information?"
steps:
  - screen: Business section
    instruction: Open the banking or tax section Apple marks as incomplete.
    click_target: "Banking" or "Tax"
    explain: Apple needs payout and tax data before paid sales can work.
    validation: The user sees Apple's official financial form.
    stop_if: The user is not authorized to provide company financial data.
  - screen: Apple banking or tax form
    instruction: Fill the form directly in Apple's UI. Spider should stay out of the values.
    click_target: visible Apple form fields
    explain: These are sensitive legal and financial fields; Spider can explain labels but must not collect the data.
    validation: Apple marks the section complete, active, or pending verification.
    stop_if: The user asks whether a tax answer is legally correct; recommend accountant/legal review.
security:
  never_collect:
    - bank account number
    - routing number
    - tax ID
    - W-8/W-9/full tax form values
official_sources:
  - https://developer.apple.com/help/app-store-connect/manage-agreements/sign-and-update-agreements
last_verified: 2026-06-17
```

### 8. Audit Privacy Labels Before Answering

```yaml
id: audit_app_privacy_labels
domain: app_store_connect_privacy
goal: Prevent false "Data Not Collected" answers.
entry_signals:
  - "App Privacy"
  - "Privacy Nutrition Label"
  - "Data Collected"
  - User says "Can I mark no data collected?"
required_role:
  - Account Holder
  - Admin
  - App Manager
preflight_questions:
  - "Does the app use login, analytics, crash reporting, backend, AI APIs, payments, push, ads, maps, storage, or support chat?"
steps:
  - screen: App Privacy overview
    instruction: Pause before selecting answers and map SDKs plus data flows.
    click_target: none
    explain: Apple requires disclosure for data collected by the app and integrated third-party partners.
    validation: Spider has a data map before recommending labels.
    stop_if: The user answers from memory without knowing SDKs or backend behavior.
  - screen: app data map
    instruction: Classify each data type by collection, purpose, linkage to user, and tracking.
    click_target: visible privacy questions
    explain: Login and analytics often turn vague "usage" into data linked to a user.
    validation: Each selected privacy answer traces back to a real app behavior or SDK.
    stop_if: The user wants to hide a data practice because it "looks bad".
security:
  never_collect:
    - production user data
    - raw logs containing personal information
official_sources:
  - https://developer.apple.com/app-store/app-privacy-details/
last_verified: 2026-06-17
```

### 9. Diagnose Missing Build In TestFlight

```yaml
id: diagnose_missing_testflight_build
domain: app_store_connect_testflight
goal: Find why an uploaded Xcode build is not visible.
entry_signals:
  - "TestFlight"
  - "Builds"
  - "Processing"
  - "No Builds"
  - User says "I uploaded but it does not appear"
required_role:
  - App access in App Store Connect
preflight_questions:
  - "What Bundle Identifier did Xcode upload, and what Bundle ID is selected in this app record?"
steps:
  - screen: TestFlight builds
    instruction: Check whether the build is still processing.
    click_target: "Builds" or "Compilacoes"
    explain: Xcode upload success only means Apple received the package; processing must finish before selection.
    validation: A build row appears with a status, or no build appears.
    stop_if: The build says Invalid Binary; read the ITMS email/log before uploading again.
  - screen: no build appears
    instruction: Compare Bundle ID in Xcode, Apple Developer App ID, and App Store Connect app record.
    click_target: relevant Bundle ID fields
    explain: A build uploaded with a different Bundle ID will not attach to this app record.
    validation: The three identifiers match exactly.
    stop_if: They do not match; do not upload another build until identity is fixed.
security:
  never_collect:
    - Apple credentials
    - signing keys
official_sources:
  - https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds
last_verified: 2026-06-17
```

### 10. Select Build And Submit For Review

```yaml
id: select_build_submit_for_review
domain: app_store_connect_review
goal: Attach the tested build to the version and submit only after required metadata is ready.
entry_signals:
  - "Prepare for Submission"
  - "Build"
  - "Add for Review"
  - "Submit for Review"
required_role:
  - Account Holder
  - Admin
  - App Manager
preflight_questions:
  - "Was this exact build installed and smoke-tested through TestFlight?"
steps:
  - screen: version page
    instruction: Scroll to the Build section and select the processed build that was tested.
    click_target: "Add Build" or "Select a build"
    explain: Review evaluates the selected binary, not whatever was last uploaded.
    validation: The build number appears attached to the app version.
    stop_if: No processed build is available.
  - screen: version metadata
    instruction: Check screenshots, description, privacy, age rating, support URL, pricing, and review notes before adding for review.
    click_target: visible incomplete sections
    explain: Most blocked submissions are missing required metadata, not mysterious Apple drama.
    validation: App Store Connect allows the version into the review draft.
    stop_if: The app requires login and no working test account is available.
security:
  never_collect:
    - production credentials
    - real customer data in screenshots
official_sources:
  - https://developer.apple.com/help/app-store-connect/manage-builds/choose-a-build
  - https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-an-app
last_verified: 2026-06-17
```

### 11. Configure IAP Or Subscription Product

```yaml
id: configure_iap_or_subscription
domain: app_store_connect_iap
goal: Create App Store Connect products that match the StoreKit implementation.
entry_signals:
  - "In-App Purchases"
  - "Subscriptions"
  - "Subscription Groups"
  - User says "create premium plan"
required_role:
  - Account Holder
  - Admin
  - App Manager where permitted
preflight_questions:
  - "What entitlement changes inside the app after purchase?"
steps:
  - screen: monetization setup
    instruction: Confirm Paid Apps Agreement, banking, and tax are active or in progress before creating products.
    click_target: "Business" or product setup status
    explain: StoreKit cannot sell products if the business setup is blocked.
    validation: Paid Apps and required financial sections are active or clearly pending Apple verification.
    stop_if: Account Holder action is required.
  - screen: IAP or subscription creation
    instruction: Choose the product type that matches the benefit.
    click_target: "Consumable", "Non-Consumable", or "Auto-Renewable Subscription"
    explain: Product type is product architecture; using consumable for permanent access is dumb and painful to unwind.
    validation: The product form asks for reference name, product ID, localization, price, and review info.
    stop_if: The user has no entitlement model.
  - screen: product fields
    instruction: Fill `Product ID` with the exact stable ID used by the app code.
    click_target: "Product ID"
    value_rule: Lowercase stable identifier, no user data, never casually changed after code integration.
    explain: StoreKit lookup depends on this exact value.
    validation: Product status advances toward ready-to-submit or ready-for-review.
    stop_if: The ID does not match the code.
security:
  never_collect:
    - banking data
    - tax data
    - shared secrets
    - App Store Server API private keys
official_sources:
  - https://developer.apple.com/help/app-store-connect/configure-in-app-purchase-settings/overview-for-configuring-in-app-purchases
last_verified: 2026-06-17
```

## Field Guidance Pattern

When Spider sees a field, it should answer in this order:

1. Field meaning.
2. Why the field matters.
3. Exact fill rule.
4. Example when safe.
5. Validation.
6. Stop condition.

Example for Bundle ID:

> `Bundle ID` is the technical identity that connects Xcode, Apple Developer, and App Store Connect. Enter the exact Bundle Identifier from the Xcode target, letter for letter. Example format: `com.company.appname`. If this does not match Xcode, your uploaded build may not appear here.

Example for SKU:

> `SKU` is internal inventory text. Users do not see it. Use something stable like `appname-ios-001`. Do not use CPF, email, client name, or anything sensitive.

Example for banking:

> This is financial setup. Fill it directly in Apple's form; I do not need to see the values. I can explain what a field means, but I should not collect bank or tax data.

## Pointing Rules

Spider can point visually when confidence is high.

High-confidence pointing:

- visible button text matches expected runbook step;
- visible sidebar item matches expected domain;
- screen heading confirms the current stage;
- target is not a destructive or legal acceptance button.

Medium-confidence guidance:

- tell the user where to look, but do not animate a precise click;
- ask for one visible heading if needed.

Never auto-point or strongly instruct clicking:

- `Agree` on legal terms;
- `Submit for Review`;
- `Remove App`;
- `Delete`;
- `Revoke Certificate`;
- `Transfer App`;
- `Accept Paid Apps Agreement`;
- banking/tax submit buttons;
- API key creation/download buttons;
- anything involving private keys or account recovery.

For those, Spider should explain the consequence and ask the user to confirm intent.

## Official Source Refresh

The PDF should be refreshed into runbooks through this pipeline:

1. Extract PDF text into normalized Markdown.
2. Split into task candidates by user goal, not by chapter number.
3. Convert each task into the runbook schema above.
4. Attach official Apple source URLs to each task.
5. Mark each task with `last_verified`.
6. Add screen signatures: headings, labels, buttons, URL fragments, and common error strings.
7. Add stop conditions and security boundaries.
8. Test with screenshots from real Apple Developer/App Store Connect screens.

No runbook should ship without:

- at least one entry signal;
- a role requirement;
- a stop condition;
- a security boundary;
- a validation step;
- an official source URL for drift-prone Apple behavior.

## Minimum Dataset To Build Next

Convert these first because they cover most beginner pain:

- `enroll_apple_developer_program`
- `choose_individual_vs_organization_membership`
- `invite_developer_or_app_manager`
- `register_explicit_app_id_bundle_id`
- `enable_app_id_capabilities`
- `prefer_xcode_automatic_signing`
- `create_app_store_connect_app_record`
- `diagnose_missing_testflight_build`
- `audit_app_privacy_labels`
- `sign_paid_apps_agreement`
- `complete_banking_tax_setup`
- `configure_iap_or_subscription`
- `select_build_submit_for_review`
- `respond_to_app_review_rejection`

The source PDF is enough to bootstrap these, but the final runbooks need official-source verification and real-screen screenshots before being used as production guidance.

## Implementation Notes For Spider

The app already has the right product shape: screen capture, GPT Vision guide response, overlay pointing, spoken guidance, and a server-side OpenAI path. The missing layer is a retrieval/knowledge policy that injects the right runbook into the guide prompt when the screen is Apple Developer or App Store Connect.

Recommended retrieval behavior:

1. Classify screen domain from screenshot and OCR text.
2. Retrieve one to three candidate runbooks.
3. Ask the model to choose the current step and return a structured guide response.
4. Force the model to include stop conditions for sensitive or irreversible actions.
5. Prefer field-level guidance over broad explanation.
6. Log only privacy-safe metadata such as runbook ID and confidence, never screenshot text or user values.

Recommended model instruction:

> You are Spider, a screen-first guide for non-technical users publishing iOS apps. Use the runbook as the operating procedure. Give one next action. Point only when the target is visible and safe. Never collect Apple passwords, 2FA codes, bank data, tax data, private keys, or secrets. For legal, payment, privacy, review, and policy topics, say when official Apple docs must be checked.

## Final Position

Use the PDF. Do not worship it. The useful unit for Spider is not a chapter; it is a task runbook with a click target, a field rule, a validation, and a stop condition.

Apple distribution is bureaucracy with sharp edges. Spider's job is to make the next edge visible before the user bleeds time on it.
