import { InMemoryFs } from "just-bash";

function createUnsupportedOperationError(operationName) {
  return new Error(
    `${operationName} is not supported by the Postgres-backed workspace filesystem.`,
  );
}

function sortWorkspaceEntriesForInitialization(workspaceEntries) {
  return [...workspaceEntries].sort((leftWorkspaceEntry, rightWorkspaceEntry) => {
    if (leftWorkspaceEntry.entryType !== rightWorkspaceEntry.entryType) {
      return leftWorkspaceEntry.entryType === "directory" ? -1 : 1;
    }

    return leftWorkspaceEntry.entryPath.localeCompare(rightWorkspaceEntry.entryPath);
  });
}

export class PostgresWorkspaceFilesystem {
  constructor(workspaceEntries) {
    this.baseFilesystem = new InMemoryFs();
    this.loadWorkspaceEntries(workspaceEntries);
  }

  loadWorkspaceEntries(workspaceEntries) {
    for (const workspaceEntry of sortWorkspaceEntriesForInitialization(workspaceEntries)) {
      if (workspaceEntry.entryPath === "/") {
        continue;
      }

      if (workspaceEntry.entryType === "directory") {
        this.baseFilesystem.mkdirSync(workspaceEntry.entryPath, { recursive: true });
        continue;
      }

      const fileContent =
        workspaceEntry.fileEncoding === "base64"
          ? Uint8Array.from(Buffer.from(workspaceEntry.fileContent || "", "base64"))
          : workspaceEntry.fileContent || "";

      this.baseFilesystem.writeFileSync(workspaceEntry.entryPath, fileContent);
    }
  }

  async exportWorkspaceEntries() {
    const allFilesystemPaths = this.baseFilesystem
      .getAllPaths()
      .filter((filesystemPath) => filesystemPath !== "")
      .sort((leftFilesystemPath, rightFilesystemPath) =>
        leftFilesystemPath.localeCompare(rightFilesystemPath),
      );

    const exportedWorkspaceEntries = [];

    for (const filesystemPath of allFilesystemPaths) {
      const filesystemStat = await this.baseFilesystem.lstat(filesystemPath);

      if (filesystemStat.isSymbolicLink) {
        throw createUnsupportedOperationError("symlink persistence");
      }

      if (filesystemStat.isDirectory) {
        exportedWorkspaceEntries.push({
          entryPath: filesystemPath,
          entryType: "directory",
        });
        continue;
      }

      const fileBuffer = Buffer.from(await this.baseFilesystem.readFileBuffer(filesystemPath));
      let fileEncoding = "base64";
      let fileContent = fileBuffer.toString("base64");

      try {
        fileContent = fileBuffer.toString("utf8");
        if (Buffer.from(fileContent, "utf8").equals(fileBuffer)) {
          fileEncoding = "utf-8";
        } else {
          fileContent = fileBuffer.toString("base64");
        }
      } catch {
        fileEncoding = "base64";
        fileContent = fileBuffer.toString("base64");
      }

      exportedWorkspaceEntries.push({
        entryPath: filesystemPath,
        entryType: "file",
        fileEncoding,
        fileContent,
      });
    }

    if (!exportedWorkspaceEntries.some((workspaceEntry) => workspaceEntry.entryPath === "/")) {
      exportedWorkspaceEntries.unshift({
        entryPath: "/",
        entryType: "directory",
      });
    }

    return exportedWorkspaceEntries;
  }

  readFile(path, options) {
    return this.baseFilesystem.readFile(path, options);
  }

  readFileBuffer(path) {
    return this.baseFilesystem.readFileBuffer(path);
  }

  writeFile(path, content, options) {
    return this.baseFilesystem.writeFile(path, content, options);
  }

  appendFile(path, content, options) {
    return this.baseFilesystem.appendFile(path, content, options);
  }

  exists(path) {
    return this.baseFilesystem.exists(path);
  }

  stat(path) {
    return this.baseFilesystem.stat(path);
  }

  lstat(path) {
    return this.baseFilesystem.lstat(path);
  }

  mkdir(path, options) {
    return this.baseFilesystem.mkdir(path, options);
  }

  readdir(path) {
    return this.baseFilesystem.readdir(path);
  }

  readdirWithFileTypes(path) {
    return this.baseFilesystem.readdirWithFileTypes(path);
  }

  rm(path, options) {
    return this.baseFilesystem.rm(path, options);
  }

  cp(sourcePath, destinationPath, options) {
    return this.baseFilesystem.cp(sourcePath, destinationPath, options);
  }

  mv(sourcePath, destinationPath) {
    return this.baseFilesystem.mv(sourcePath, destinationPath);
  }

  resolvePath(basePath, path) {
    return this.baseFilesystem.resolvePath(basePath, path);
  }

  getAllPaths() {
    return this.baseFilesystem.getAllPaths();
  }

  chmod(path, mode) {
    return this.baseFilesystem.chmod(path, mode);
  }

  symlink() {
    throw createUnsupportedOperationError("symlink");
  }

  link() {
    throw createUnsupportedOperationError("hard link");
  }

  readlink() {
    throw createUnsupportedOperationError("readlink");
  }

  realpath(path) {
    return this.baseFilesystem.realpath(path);
  }

  utimes(path, atime, mtime) {
    return this.baseFilesystem.utimes(path, atime, mtime);
  }
}
