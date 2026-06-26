const WORKTREE_REVIEW_GROUPS = [
  {
    id: "tests",
    title: "Tests",
    commit: "domain-tests-and-smoke-coverage",
    matches: (filePath) => filePath.startsWith("leanring-buddyTests/")
      || filePath.startsWith("worker/tests/"),
  },
  {
    id: "xcode-assets-deletions",
    title: "Xcode project, assets, deletions",
    commit: "xcode-assets-legacy-provider-removal",
    matches: (filePath, entry) => filePath.includes(".xcodeproj/")
      || filePath.startsWith("Assets/")
      || filePath.includes("Assets.xcassets/")
      || filePath === "appcast.xml"
      || filePath === "clicky-demo.gif"
      || entry.changeKind === "deleted",
  },
  {
    id: "guided-setup-dot-sensor-fusion",
    title: "Guided setup, dot, sensor fusion",
    commit: "guided-setup-dot-sensor-fusion",
    matches: (filePath) => /(^|\/)(GuidedSetup|Grounding|GuidePoint|SpiderGuide|CompanionGuidePoint|CompanionPreDot|OpenAIVisionGuide|GuideResponsePresentation|VisualGrounding|render_mission_pointer)/.test(filePath),
  },
  {
    id: "telemetry-privacy",
    title: "Telemetry and privacy",
    commit: "telemetry-privacy-boundaries",
    matches: (filePath) => /(SpiderAnalytics|SpiderGroundingAnalytics|SpiderGroundingTelemetry|GroundingTelemetry|groundingTelemetry|grounding_telemetry|SpiderGroundingPrivacy|Privacy)/.test(filePath),
  },
  {
    id: "worker-backend",
    title: "Worker backend",
    commit: "worker-routing-auth-openai-safety",
    matches: (filePath) => filePath.startsWith("worker/")
      && !filePath.startsWith("worker/tests/"),
  },
  {
    id: "docs-scripts-release",
    title: "Docs, scripts, release gates",
    commit: "docs-scripts-release-gates",
    matches: (filePath) => /^(scripts\/|docs\/|README\.md|AGENTS\.md|leanring-buddy\/AGENTS\.md|SPIDER_.*\.md)/.test(filePath),
  },
  {
    id: "app-macos-core",
    title: "App macOS core",
    commit: "macos-core-boundaries",
    matches: (filePath) => filePath.startsWith("leanring-buddy/"),
  },
  {
    id: "repo-metadata",
    title: "Repository metadata",
    commit: "repo-metadata-cleanup",
    matches: (filePath) => filePath === ".gitignore" || filePath === ".gitattributes",
  },
  {
    id: "review-needed",
    title: "Needs manual classification",
    commit: "manual-review",
    matches: () => true,
  },
];

const WORKTREE_REVIEW_RULES = [
  {
    tag: "manual-review",
    reason: "project metadata, release artifacts, lockfiles, config, or deletion",
    matches: (entry) => entry.changeKind === "deleted"
      || entry.path.startsWith("Assets/")
      || entry.path.includes(".xcodeproj/")
      || entry.path.includes("Package.resolved")
      || entry.path.endsWith("package-lock.json")
      || entry.path.endsWith("wrangler.toml")
      || entry.path === "appcast.xml",
  },
  {
    tag: "security-review",
    reason: "auth, billing, session, token, payload, parsing, safety, validation, OpenAI, Stripe, or telemetry boundary",
    matches: (entry) => /(auth|billing|session|token|payload|parsing|safety|validation|openai|stripe|telemetry|privacy|secret|keychain|entitlement)/i.test(entry.path),
  },
  {
    tag: "behavior-critical",
    reason: "screen guidance, dot eligibility, voice, overlay, or Worker routing",
    matches: (entry) => /(Companion|GuidedSetup|Grounding|GuidePoint|Overlay|Voice|VisionGuide|workerRoutes|visionGuide|guidePointParsing|guideScreenSafety|guidePointSafety|guideResponseValidation)/.test(entry.path),
  },
];

export { WORKTREE_REVIEW_GROUPS, WORKTREE_REVIEW_RULES };
