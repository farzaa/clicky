import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

export function registerWorktreeReviewAssertions({ test, workerRoot }) {
  test("worktree review CLI keeps commit grouping outside a script monolith", async () => {
    const scriptsRoot = path.join(workerRoot, "..", "scripts");
    const cliSource = readFileSync(path.join(scriptsRoot, "worktree_review_groups.mjs"), "utf8");
    const configSource = readFileSync(path.join(scriptsRoot, "worktreeReviewGroupsConfig.mjs"), "utf8");
    const gitSource = readFileSync(path.join(scriptsRoot, "worktreeReviewGroupsGit.mjs"), "utf8");
    const classifierSource = readFileSync(path.join(scriptsRoot, "worktreeReviewGroupsClassifier.mjs"), "utf8");
    const rendererSource = readFileSync(path.join(scriptsRoot, "worktreeReviewGroupsRenderer.mjs"), "utf8");
    const selfTestSource = readFileSync(path.join(scriptsRoot, "worktreeReviewGroupsSelfTest.mjs"), "utf8");
    const argsSource = readFileSync(path.join(scriptsRoot, "worktreeReviewGroupsArgs.mjs"), "utf8");
    const readmeSource = readFileSync(path.join(scriptsRoot, "README.md"), "utf8");
    const cliLineCount = cliSource.split(/\r?\n/).length;

    assert.ok(cliLineCount <= 80, `worktree review entrypoint is too large: ${cliLineCount}`);
    assert.match(cliSource, /from "\.\/worktreeReviewGroupsArgs\.mjs"/);
    assert.match(cliSource, /from "\.\/worktreeReviewGroupsClassifier\.mjs"/);
    assert.match(cliSource, /from "\.\/worktreeReviewGroupsGit\.mjs"/);
    assert.match(cliSource, /from "\.\/worktreeReviewGroupsRenderer\.mjs"/);
    assert.match(cliSource, /from "\.\/worktreeReviewGroupsSelfTest\.mjs"/);
    assert.match(cliSource, /renderPaths/);
    assert.match(configSource, /guided-setup-dot-sensor-fusion/);
    assert.match(configSource, /telemetry-privacy-boundaries/);
    assert.match(configSource, /worker-routing-auth-openai-safety/);
    assert.match(configSource, /guidePointParsing/);
    assert.match(configSource, /guideScreenSafety/);
    assert.match(configSource, /parsing\|safety\|validation/);
    assert.match(configSource, /startsWith\("Assets\/"\)/);
    assert.match(configSource, /xcode-assets-legacy-provider-removal/);
    assert.match(gitSource, /status", "--porcelain=v1", "-z", "--untracked-files=all"/);
    assert.match(classifierSource, /configuredGroupIds/);
    assert.match(classifierSource, /filterReviewByFlag/);
    assert.match(classifierSource, /filterReviewByGroup/);
    assert.match(rendererSource, /Review group id/);
    assert.match(rendererSource, /No changed paths matched this filter/);
    assert.match(rendererSource, /function renderPaths/);
    assert.match(rendererSource, /Keep v2 channel-agnostic ads work out of this diff/);
    assert.match(selfTestSource, /runWorktreeReviewSelfTest/);
    assert.match(argsSource, /--group/);
    assert.match(argsSource, /--flag/);
    assert.match(argsSource, /--paths/);
    assert.match(argsSource, /--null/);
    assert.match(readmeSource, /--paths --null/);
    assert.match(readmeSource, /--pathspec-file-nul/);
  });

  test("worktree review exposes pure grouping for commit-split review", async () => {
    const scriptPath = path.join(workerRoot, "..", "scripts", "worktree_review_groups.mjs");
    const reviewTool = await import(pathToFileURL(scriptPath).href);
    const review = reviewTool.buildReview([
      { status: "??", path: "leanring-buddy/SpiderGroundingTelemetry.swift", changeKind: "untracked" },
      { status: " M", path: "worker/src/workerRoutes.ts", changeKind: "modified" },
      { status: "??", path: "worker/src/guidePointParsing.ts", changeKind: "untracked" },
      { status: "??", path: "worker/src/guideScreenSafety.ts", changeKind: "untracked" },
      { status: "??", path: "Assets/Home.png", changeKind: "untracked" },
      { status: " D", path: "leanring-buddy/ClaudeAPI.swift", changeKind: "deleted" },
    ]);

    assert.equal(review.totalFiles, 6);
    assert.equal(review.groups.find((group) => group.id === "telemetry-privacy").files.length, 1);
    assert.equal(review.groups.find((group) => group.id === "worker-backend").files.length, 3);
    assert.equal(review.groups.find((group) => group.id === "xcode-assets-deletions").files.length, 2);

    const workerReview = reviewTool.filterReviewByGroup(review, "worker-backend");
    assert.equal(workerReview.totalFiles, 3);
    assert.equal(workerReview.groups[0].commit, "worker-routing-auth-openai-safety");
    const behaviorReview = reviewTool.filterReviewByFlag(review, "behavior-critical");
    assert.equal(behaviorReview.totalFiles, 4);
    assert.deepEqual(behaviorReview.groups.map((group) => group.id), [
      "telemetry-privacy",
      "worker-backend",
    ]);
    const behaviorWorkerReview = reviewTool.filterReviewByFlag(workerReview, "behavior-critical");
    assert.equal(behaviorWorkerReview.totalFiles, 3);
    assert.equal(behaviorWorkerReview.groups[0].id, "worker-backend");
    const emptyConfiguredReview = reviewTool.filterReviewByGroup(review, "review-needed");
    assert.equal(emptyConfiguredReview.totalFiles, 0);
    assert.match(
      reviewTool.renderMarkdown(emptyConfiguredReview),
      /No changed paths matched this filter/
    );
    assert.match(
      reviewTool.renderPaths(reviewTool.filterReviewByGroup(review, "xcode-assets-deletions")),
      /Assets\/Home\.png\n/
    );
    assert.match(
      reviewTool.renderPaths(reviewTool.filterReviewByGroup(review, "xcode-assets-deletions"), { nullTerminated: true }),
      /Assets\/Home\.png\0/
    );
    assert.match(
      reviewTool.renderMarkdown(workerReview, { includeFiles: false }),
      /Review group id: `worker-backend`/
    );
    assert.deepEqual(reviewTool.parseWorktreeReviewArgs(["--json", "--group", "telemetry-privacy"]), {
      format: "json",
      includeFiles: true,
      groupId: "telemetry-privacy",
      nullTerminated: false,
      reviewFlag: null,
      selfTest: false,
    });
    assert.deepEqual(reviewTool.parseWorktreeReviewArgs(["--paths", "--null", "--group=xcode-assets-deletions"]), {
      format: "paths",
      includeFiles: true,
      groupId: "xcode-assets-deletions",
      nullTerminated: true,
      reviewFlag: null,
      selfTest: false,
    });
    assert.equal(
      reviewTool.parseWorktreeReviewArgs(["--flag=security-review"]).reviewFlag,
      "security-review"
    );
    assert.equal(reviewTool.runWorktreeReviewSelfTest().ok, true);
  });
}
