import { MAX_OPENAI_RESPONSE_BYTES } from "./guideLimits";
import { HttpError } from "./http";
import {
  parseJSONText,
  readBoundedResponseText,
} from "./payloadSecurity";
import { asRecord } from "./structuredValues";

export async function readOpenAIGuideOutputText(response: Response): Promise<string> {
  const responseText = await readBoundedResponseText(
    response,
    MAX_OPENAI_RESPONSE_BYTES,
    "OpenAI vision response is too large."
  );
  if (!response.ok) {
    throw new HttpError(response.status, "OpenAI vision request failed.");
  }

  const parsed = parseJSONText(responseText, "OpenAI returned an invalid vision response.", 502);
  const outputText = extractOpenAIOutputText(parsed);
  if (!outputText) {
    throw new HttpError(502, "OpenAI returned no guide response.");
  }

  return outputText;
}

function extractOpenAIOutputText(response: unknown): string | null {
  const root = asRecord(response);
  if (typeof root.output_text === "string") {
    return root.output_text;
  }

  const output = Array.isArray(root.output) ? root.output : [];
  for (const itemValue of output) {
    const item = asRecord(itemValue);
    const contents = Array.isArray(item.content) ? item.content : [];
    for (const contentValue of contents) {
      const content = asRecord(contentValue);
      if (content.type === "output_text" && typeof content.text === "string") {
        return content.text;
      }
    }
  }
  return null;
}
