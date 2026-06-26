import assert from "node:assert/strict";
import {
  buildReview,
  filterReviewByFlag,
  filterReviewByGroup,
} from "./worktreeReviewGroupsClassifier.mjs";
import { parseWorktreeReviewArgs } from "./worktreeReviewGroupsArgs.mjs";
import {
  renderMarkdown,
  renderPaths,
} from "./worktreeReviewGroupsRenderer.mjs";

function runWorktreeReviewSelfTest() {
  const review = buildReview([
    { status: " M", path: "leanring-buddy/CompanionManager.swift", changeKind: "modified" },
    { status: "??", path: "leanring-buddy/GroundingSensorFusionDecisionResolver.swift", changeKind: "untracked" },
    { status: "??", path: "leanring-buddy/SpiderGroundingTelemetry.swift", changeKind: "untracked" },
    { status: " M", path: "worker/src/workerRoutes.ts", changeKind: "modified" },
    { status: "??", path: "worker/src/guidePointParsing.ts", changeKind: "untracked" },
    { status: "??", path: "worker/src/guideScreenSafety.ts", changeKind: "untracked" },
    { status: "??", path: "worker/tests/smoke-worker.mjs", changeKind: "untracked" },
    { status: "??", path: "Assets/Home.png", changeKind: "untracked" },
    { status: " D", path: "leanring-buddy/Assets.xcassets/legacy.imageset/Contents.json", changeKind: "deleted" },
    { status: " M", path: "scripts/release.sh", changeKind: "modified" },
  ]);

  assert.equal(review.totalFiles, 10);
  assert.equal(review.groups.find((group) => group.id === "guided-setup-dot-sensor-fusion").files.length, 1);
  assert.equal(review.groups.find((group) => group.id === "telemetry-privacy").files.length, 1);
  assert.equal(review.groups.find((group) => group.id === "worker-backend").files.length, 3);
  assert.equal(review.groups.find((group) => group.id === "tests").files.length, 1);
  assert.equal(review.groups.find((group) => group.id === "xcode-assets-deletions").files.length, 2);
  const referenceAsset = review.groups
    .find((group) => group.id === "xcode-assets-deletions")
    .files.find((entry) => entry.path === "Assets/Home.png");
  assert.equal(referenceAsset.reviewTags.some((reviewTag) => reviewTag.tag === "manual-review"), true);
  assert.equal(review.groups.find((group) => group.id === "docs-scripts-release").files.length, 1);
  assert.ok(review.reviewFlags.some((flag) => flag.tag === "manual-review"));
  assert.ok(review.reviewFlags.some((flag) => flag.tag === "security-review"));
  assert.ok(renderMarkdown(review).includes("Keep v2 channel-agnostic ads work out of this diff"));
  assert.ok(renderMarkdown(review).includes("Review group id: `worker-backend`"));
  assert.ok(renderMarkdown(review, { includeFiles: false }).includes("File list hidden"));
  assert.ok(renderPaths(review).includes("Assets/Home.png\n"));
  assert.ok(renderPaths(review, { nullTerminated: true }).includes("Assets/Home.png\0"));
  const filteredReview = filterReviewByGroup(review, "telemetry-privacy");
  assert.equal(filteredReview.totalFiles, 1);
  assert.equal(filteredReview.groups[0].id, "telemetry-privacy");
  const emptyConfiguredReview = filterReviewByGroup(review, "review-needed");
  assert.equal(emptyConfiguredReview.totalFiles, 0);
  assert.ok(renderMarkdown(emptyConfiguredReview).includes("No changed paths matched this filter."));
  const securityReview = filterReviewByFlag(review, "security-review");
  assert.equal(securityReview.totalFiles, 3);
  assert.equal(securityReview.reviewFlags.some((flag) => flag.tag === "security-review"), true);
  const behaviorWorkerReview = filterReviewByFlag(
    filterReviewByGroup(review, "worker-backend"),
    "behavior-critical"
  );
  assert.equal(behaviorWorkerReview.totalFiles, 3);
  assert.equal(behaviorWorkerReview.groups[0].id, "worker-backend");
  assert.throws(
    () => filterReviewByGroup(review, "missing-group"),
    /Unknown review group "missing-group"/
  );
  assert.throws(
    () => filterReviewByFlag(review, "missing-flag"),
    /Unknown or empty review flag "missing-flag"/
  );
  assert.deepEqual(parseWorktreeReviewArgs(["--summary", "--group=worker-backend"]), {
    format: "markdown",
    includeFiles: false,
    groupId: "worker-backend",
    nullTerminated: false,
    reviewFlag: null,
    selfTest: false,
  });
  assert.deepEqual(parseWorktreeReviewArgs(["--json", "--flag", "security-review"]), {
    format: "json",
    includeFiles: true,
    groupId: null,
    nullTerminated: false,
    reviewFlag: "security-review",
    selfTest: false,
  });
  assert.deepEqual(parseWorktreeReviewArgs(["--paths", "--null", "--group", "xcode-assets-deletions"]), {
    format: "paths",
    includeFiles: true,
    groupId: "xcode-assets-deletions",
    nullTerminated: true,
    reviewFlag: null,
    selfTest: false,
  });

  return { ok: true, totalFiles: review.totalFiles };
}

export { runWorktreeReviewSelfTest };
