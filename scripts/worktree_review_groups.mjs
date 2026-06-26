#!/usr/bin/env node

import { pathToFileURL } from "node:url";
import { parseWorktreeReviewArgs } from "./worktreeReviewGroupsArgs.mjs";
import {
  buildReview,
  filterReviewByFlag,
  filterReviewByGroup,
} from "./worktreeReviewGroupsClassifier.mjs";
import {
  parsePorcelainStatus,
  readWorktreeEntries,
} from "./worktreeReviewGroupsGit.mjs";
import {
  renderMarkdown,
  renderPaths,
} from "./worktreeReviewGroupsRenderer.mjs";
import { runWorktreeReviewSelfTest } from "./worktreeReviewGroupsSelfTest.mjs";

function main(args = process.argv.slice(2)) {
  const options = parseWorktreeReviewArgs(args);
  if (options.selfTest) {
    console.log(JSON.stringify(runWorktreeReviewSelfTest(), null, 2));
    return;
  }

  const review = filterReviewByFlag(
    filterReviewByGroup(
      buildReview(readWorktreeEntries()),
      options.groupId
    ),
    options.reviewFlag
  );

  if (options.format === "json") {
    console.log(JSON.stringify(review, null, 2));
    return;
  }
  if (options.format === "paths") {
    process.stdout.write(renderPaths(review, { nullTerminated: options.nullTerminated }));
    return;
  }

  console.log(renderMarkdown(review, { includeFiles: options.includeFiles }));
}

export {
  buildReview,
  filterReviewByFlag,
  filterReviewByGroup,
  main,
  parsePorcelainStatus,
  parseWorktreeReviewArgs,
  renderMarkdown,
  renderPaths,
  runWorktreeReviewSelfTest,
};

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main();
}
