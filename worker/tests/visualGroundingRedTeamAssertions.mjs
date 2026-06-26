import { readFileSync } from "node:fs";
import path from "node:path";
import assert from "node:assert/strict";

export function registerVisualGroundingRedTeamAssertions({ test, workerRoot }) {
  test("red-team visual grounding cases stay metadata-only and cover hard boundaries", () => {
    const redTeamPath = path.join(workerRoot, "evals", "fixtures", "red-team-visual-cases.json");
    const redTeam = JSON.parse(readFileSync(redTeamPath, "utf8"));
    const requiredCaseIds = new Set([
      "modal_over_safe_target",
      "disabled_primary_button",
      "partially_occluded_target",
      "stale_loading_screen",
      "dangerous_button_near_safe_button",
      "similar_objective_tiles",
      "localized_layout",
      "dropdown_open",
      "table_with_dangerous_row_actions",
      "billing_publish_budget_boundary",
    ]);

    assert.equal(redTeam.privacy.screenshots, false);
    assert.equal(redTeam.privacy.rawOCR, false);
    assert.equal(redTeam.privacy.rawAX, false);
    assert.equal(redTeam.privacy.rawDOM, false);
    assert.equal(redTeam.privacy.rawLabels, false);
    for (const caseId of requiredCaseIds) {
      assert.ok(redTeam.cases.some((testCase) => testCase.id === caseId), `Missing red-team case ${caseId}`);
    }
    assert.doesNotMatch(JSON.stringify(redTeam), /imageBase64|screenshotPath|rawOCRText|rawAXPayload|rawDOMPayload|ariaLabel|nearestText/i);
  });
}
