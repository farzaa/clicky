import { Bash } from "just-bash";

import { PostgresWorkspaceFilesystem } from "./postgres_workspace_filesystem.mjs";

async function readJsonFromStandardInput() {
  let rawStandardInput = "";
  process.stdin.setEncoding("utf8");

  for await (const standardInputChunk of process.stdin) {
    rawStandardInput += standardInputChunk;
  }

  return JSON.parse(rawStandardInput || "{}");
}

async function main() {
  const executionRequest = await readJsonFromStandardInput();
  const postgresWorkspaceFilesystem = new PostgresWorkspaceFilesystem(
    executionRequest.workspaceEntries || [],
  );
  const bash = new Bash({
    fs: postgresWorkspaceFilesystem,
    cwd: "/",
  });
  const abortController = new AbortController();
  const timeoutHandle = setTimeout(() => {
    abortController.abort();
  }, executionRequest.timeoutMs);

  try {
    const executionResult = await bash.exec(executionRequest.script, {
      cwd: executionRequest.workingDirectory || "/",
      stdin: executionRequest.stdin || "",
      env: executionRequest.environmentVariables || {},
      signal: abortController.signal,
    });

    process.stdout.write(
      JSON.stringify({
        stdout: executionResult.stdout,
        stderr: executionResult.stderr,
        exitCode: executionResult.exitCode,
        workspaceEntries: await postgresWorkspaceFilesystem.exportWorkspaceEntries(),
      }),
    );
  } catch (error) {
    process.stdout.write(
      JSON.stringify({
        stdout: "",
        stderr: error instanceof Error ? error.message : String(error),
        exitCode: 1,
        workspaceEntries: await postgresWorkspaceFilesystem.exportWorkspaceEntries(),
      }),
    );
  } finally {
    clearTimeout(timeoutHandle);
  }
}

await main();
