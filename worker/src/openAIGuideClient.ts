import { readOpenAIGuideOutputText } from "./openAIGuideResponse";

interface OpenAIGuideRequestInput {
  apiKey: string;
  payload: Record<string, unknown>;
  safetyIdentifier: string;
}

export async function requestOpenAIGuideOutputText(input: OpenAIGuideRequestInput): Promise<string> {
  const response = await fetch("https://api.openai.com/v1/responses", {
    method: "POST",
    headers: {
      authorization: `Bearer ${input.apiKey}`,
      "content-type": "application/json",
      "OpenAI-Safety-Identifier": input.safetyIdentifier,
    },
    body: JSON.stringify(input.payload),
  });

  return await readOpenAIGuideOutputText(response);
}
