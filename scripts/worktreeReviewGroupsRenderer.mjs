function renderMarkdown(review, options = {}) {
  const includeFiles = options.includeFiles ?? true;
  const lines = [
    "# Spider Worktree Review Groups",
    "",
    `Total changed paths: ${review.totalFiles}`,
    "",
    "## Suggested Commit Groups",
    "",
  ];

  if (review.groups.length === 0) {
    lines.push("No changed paths matched this filter.");
    lines.push("");
  }

  for (const group of review.groups) {
    lines.push(`### ${group.title}`);
    lines.push(`- Review group id: \`${group.id}\``);
    lines.push(`- Commit group: \`${group.commit}\``);
    lines.push(`- Count: ${group.files.length}`);
    lines.push(`- Kinds: ${formatCounts(group.counts)}`);
    lines.push("");

    if (includeFiles) {
      for (const entry of group.files) {
        const tags = entry.reviewTags.length > 0
          ? ` [${entry.reviewTags.map((reviewTag) => reviewTag.tag).join(", ")}]`
          : "";
        lines.push(`  - ${entry.status.trim() || "M"} ${entry.path}${tags}`);
      }
    } else {
      lines.push("  - File list hidden. Run without `--summary` for path-level review.");
    }

    lines.push("");
  }

  lines.push("## Manual Review Flags");
  lines.push("");

  if (review.reviewFlags.length === 0) {
    lines.push("- None");
  } else {
    for (const flag of review.reviewFlags) {
      lines.push(`- ${flag.tag}: ${flag.files.length} files (${flag.reason})`);
    }
  }

  lines.push("");
  lines.push("## Review Order");
  lines.push("");
  lines.push("1. Review security and telemetry boundaries before UI or release artifacts.");
  lines.push("2. Review guided setup, dot, and sensor fusion as one behavior-critical unit.");
  lines.push("3. Review Worker routing, auth, entitlement, OpenAI, and payload validation together.");
  lines.push("4. Review Xcode project, assets, lockfiles, and deletions last and manually.");
  lines.push("5. Keep v2 channel-agnostic ads work out of this diff unless it is a tiny contract-only seam.");
  lines.push("");

  return `${lines.join("\n")}\n`;
}

function renderPaths(review, options = {}) {
  const separator = options.nullTerminated ? "\0" : "\n";
  const paths = review.groups.flatMap((group) => group.files.map((entry) => entry.path));
  if (paths.length === 0) {
    return "";
  }
  return `${paths.join(separator)}${separator}`;
}

function formatCounts(counts) {
  return Object.keys(counts)
    .sort()
    .map((kind) => `${kind}=${counts[kind]}`)
    .join(", ");
}

export { renderMarkdown, renderPaths };
