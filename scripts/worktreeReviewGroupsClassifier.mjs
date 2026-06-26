import {
  WORKTREE_REVIEW_GROUPS,
  WORKTREE_REVIEW_RULES,
} from "./worktreeReviewGroupsConfig.mjs";

function buildReview(entries) {
  const classifiedEntries = entries.map(classifyEntry);
  const groups = WORKTREE_REVIEW_GROUPS.map((group) => {
    const files = classifiedEntries.filter((entry) => entry.groupId === group.id);
    return {
      id: group.id,
      title: group.title,
      commit: group.commit,
      counts: countByKind(files),
      files,
    };
  }).filter((group) => group.files.length > 0);

  return {
    totalFiles: classifiedEntries.length,
    groups,
    reviewFlags: summarizeReviewFlags(classifiedEntries),
  };
}

function filterReviewByGroup(review, groupId) {
  if (!groupId) {
    return review;
  }

  const groups = review.groups.filter((group) => group.id === groupId);
  if (groups.length === 0) {
    const configuredGroupIds = WORKTREE_REVIEW_GROUPS.map((group) => group.id);
    if (configuredGroupIds.includes(groupId)) {
      return {
        totalFiles: 0,
        groups: [],
        reviewFlags: [],
      };
    }

    const availableGroups = configuredGroupIds.join(", ");
    throw new Error(`Unknown review group "${groupId}". Available groups: ${availableGroups}`);
  }

  const files = groups.flatMap((group) => group.files);
  const flaggedPaths = new Set(files.map((file) => file.path));
  return {
    totalFiles: files.length,
    groups,
    reviewFlags: review.reviewFlags
      .map((flag) => ({
        ...flag,
        files: flag.files.filter((filePath) => flaggedPaths.has(filePath)),
      }))
      .filter((flag) => flag.files.length > 0),
  };
}

function filterReviewByFlag(review, reviewFlag) {
  if (!reviewFlag) {
    return review;
  }

  const groups = review.groups
    .map((group) => {
      const files = group.files.filter((entry) => entry.reviewTags.some((tag) => tag.tag === reviewFlag));
      return {
        ...group,
        counts: countByKind(files),
        files,
      };
    })
    .filter((group) => group.files.length > 0);
  if (groups.length === 0) {
    const availableFlags = review.reviewFlags.map((flag) => flag.tag).join(", ");
    throw new Error(`Unknown or empty review flag "${reviewFlag}". Available flags: ${availableFlags}`);
  }

  const files = groups.flatMap((group) => group.files);
  return {
    totalFiles: files.length,
    groups,
    reviewFlags: summarizeReviewFlags(files),
  };
}

function classifyEntry(entry) {
  const group = WORKTREE_REVIEW_GROUPS.find((candidate) => candidate.matches(entry.path, entry));
  const reviewTags = WORKTREE_REVIEW_RULES
    .filter((rule) => rule.matches(entry))
    .map((rule) => ({ tag: rule.tag, reason: rule.reason }));

  return {
    ...entry,
    groupId: group.id,
    groupTitle: group.title,
    commitGroup: group.commit,
    reviewTags,
  };
}

function countByKind(entries) {
  return entries.reduce(
    (counts, entry) => {
      counts[entry.changeKind] = (counts[entry.changeKind] ?? 0) + 1;
      return counts;
    },
    {}
  );
}

function summarizeReviewFlags(entries) {
  const flagged = new Map();

  for (const entry of entries) {
    for (const reviewTag of entry.reviewTags) {
      const current = flagged.get(reviewTag.tag) ?? {
        tag: reviewTag.tag,
        reason: reviewTag.reason,
        files: [],
      };
      current.files.push(entry.path);
      flagged.set(reviewTag.tag, current);
    }
  }

  return [...flagged.values()].sort((left, right) => left.tag.localeCompare(right.tag));
}

export { buildReview, classifyEntry, filterReviewByFlag, filterReviewByGroup };
