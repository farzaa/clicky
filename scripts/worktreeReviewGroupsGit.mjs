import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import path from "node:path";

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

function runGit(args, repoRoot = REPO_ROOT) {
  const result = spawnSync("git", args, {
    cwd: repoRoot,
    encoding: "utf8",
    maxBuffer: 16 * 1024 * 1024,
  });

  if (result.status !== 0) {
    throw new Error((result.stderr || result.stdout || "git command failed").trim());
  }

  return result.stdout;
}

function readWorktreeEntries() {
  const rawStatus = runGit(["status", "--porcelain=v1", "-z", "--untracked-files=all"]);
  return parsePorcelainStatus(rawStatus);
}

function parsePorcelainStatus(rawStatus) {
  const parts = rawStatus.split("\0").filter(Boolean);
  const entries = [];

  for (let index = 0; index < parts.length; index += 1) {
    const record = parts[index];
    const status = record.slice(0, 2);
    const filePath = record.slice(3);
    const isRenameOrCopy = status.includes("R") || status.includes("C");
    const previousPath = isRenameOrCopy ? parts[index + 1] : undefined;

    if (isRenameOrCopy) {
      index += 1;
    }

    entries.push({
      status,
      path: filePath,
      previousPath,
      changeKind: changeKind(status),
    });
  }

  return entries;
}

function changeKind(status) {
  if (status === "??") return "untracked";
  if (status.includes("D")) return "deleted";
  if (status.includes("A")) return "added";
  if (status.includes("R")) return "renamed";
  if (status.includes("C")) return "copied";
  return "modified";
}

export { REPO_ROOT, changeKind, parsePorcelainStatus, readWorktreeEntries, runGit };
