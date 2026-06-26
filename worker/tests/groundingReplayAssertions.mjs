import { readFileSync } from "node:fs";
import path from "node:path";
import assert from "node:assert/strict";

export function registerGroundingReplayAssertions({ test, workerRoot }) {
  test("grounding replay is a local visual crash test, not a UI corpus", () => {
    const replaySource = readFileSync(path.join(workerRoot, "evals", "replay-grounding.mjs"), "utf8");
    const evalRunnerSource = readFileSync(path.join(workerRoot, "evals", "run-grounding-evals.mjs"), "utf8");
    const fixturesReadme = readFileSync(path.join(workerRoot, "evals", "fixtures", "README.md"), "utf8");
    const casesReadme = readFileSync(path.join(workerRoot, "evals", "cases", "README.md"), "utf8");
    const casesIgnore = readFileSync(path.join(workerRoot, "evals", "cases", ".gitignore"), "utf8");
    const reportsIgnore = readFileSync(path.join(workerRoot, "evals", "reports", ".gitignore"), "utf8");

    assert.match(replaySource, /safeTargets/);
    assert.match(replaySource, /blockedTargets/);
    assert.match(replaySource, /sceneGraphElements/);
    assert.match(replaySource, /scene-element/);
    assert.match(replaySource, /final-dot/);
    assert.match(replaySource, /rejectionReason/);
    assert.match(evalRunnerSource, /runCase/);
    assert.match(evalRunnerSource, /index\.html/);
    assert.match(fixturesReadme, /Keep real screenshots and guide JSON captures out of git/);
    assert.match(casesReadme, /synthetic, public, or explicitly consented cases only/);
    assert.match(casesReadme, /not a source of truth/);
    assert.match(fixturesReadme, /not a UI corpus, a pixel map, or a source of truth/);
    assert.match(casesIgnore, /^\*/);
    assert.match(reportsIgnore, /^\*/);
  });
}
