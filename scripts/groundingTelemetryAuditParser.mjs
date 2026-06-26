export function parseMetricLine(line) {
  const match = line.match(/(?:Spider metric: |Spider grounding: )?(grounding_[^:]+):(.+)$/);
  if (!match) {
    return null;
  }

  const fields = {};
  for (const part of match[2].split(":")) {
    const separatorIndex = part.indexOf("=");
    if (separatorIndex <= 0) {
      continue;
    }
    fields[part.slice(0, separatorIndex)] = part.slice(separatorIndex + 1);
  }

  return {
    name: match[1],
    fields,
  };
}

export function parseEvents(input) {
  return input
    .split(/\r?\n/)
    .map((line) => parseMetricLine(line.trim()))
    .filter(Boolean);
}
