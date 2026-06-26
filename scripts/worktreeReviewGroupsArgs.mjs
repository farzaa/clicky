function parseWorktreeReviewArgs(args) {
  return {
    format: outputFormat(args),
    includeFiles: !args.includes("--summary"),
    groupId: optionValue(args, "--group"),
    nullTerminated: args.includes("--null"),
    reviewFlag: optionValue(args, "--flag"),
    selfTest: args.includes("--self-test"),
  };
}

function outputFormat(args) {
  if (args.includes("--paths")) {
    return "paths";
  }
  if (args.includes("--json")) {
    return "json";
  }
  return "markdown";
}

function optionValue(args, optionName) {
  const inlinePrefix = `${optionName}=`;
  const inlineValue = args.find((arg) => arg.startsWith(inlinePrefix));
  if (inlineValue) {
    return inlineValue.slice(inlinePrefix.length);
  }

  const optionIndex = args.indexOf(optionName);
  if (optionIndex < 0) {
    return null;
  }

  const value = args[optionIndex + 1];
  if (!value || value.startsWith("--")) {
    throw new Error(`${optionName} requires a value.`);
  }
  return value;
}

export { parseWorktreeReviewArgs };
