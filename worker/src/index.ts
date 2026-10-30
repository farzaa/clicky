/**
 * Clicky Proxy Worker
 *
 * Normalizes Claude, OpenAI, and Gemini multimodal chat into a single
 * SSE response shape that the macOS client already knows how to parse.
 */

interface Env {
  ANTHROPIC_API_KEY: string;
  OPENAI_API_KEY: string;
  GEMINI_API_KEY: string;
  ELEVENLABS_API_KEY: string;
  ELEVENLABS_VOICE_ID: string;
  ASSEMBLYAI_API_KEY: string;
}

interface ChatConversationTurn {
  user_transcript: string;
  assistant_response: string;
}

interface ChatImageInput {
  media_type: string;
  data: string;
  label: string;
}

interface ChatRequestBody {
  model: string;
  system_prompt: string;
  conversation_history?: ChatConversationTurn[];
  images?: ChatImageInput[];
  user_prompt: string;
}

type ChatProvider = "anthropic" | "openai" | "gemini";

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (request.method === "HEAD") {
      return new Response(null, { status: 200 });
    }

    if (request.method !== "POST") {
      return new Response("Method not allowed", { status: 405 });
    }

    try {
      if (url.pathname === "/chat") {
        return await handleChat(request, env);
      }

      if (url.pathname === "/tts") {
        return await handleTTS(request, env);
      }

      if (url.pathname === "/transcribe-token") {
        return await handleTranscribeToken(env);
      }
    } catch (error) {
      console.error(`[${url.pathname}] Unhandled error:`, error);
      return new Response(JSON.stringify({ error: String(error) }), {
        status: 500,
        headers: { "content-type": "application/json" },
      });
    }

    return new Response("Not found", { status: 404 });
  },
};

async function handleChat(request: Request, env: Env): Promise<Response> {
  const requestBody = (await request.json()) as ChatRequestBody;
  validateChatRequestBody(requestBody);

  const provider = resolveChatProvider(requestBody.model);
  let responseText = "";

  if (provider === "anthropic") {
    responseText = await requestAnthropicChat(requestBody, env);
  } else if (provider === "openai") {
    responseText = await requestOpenAIChat(requestBody, env);
  } else {
    responseText = await requestGeminiChat(requestBody, env);
  }

  return makeNormalizedSSEResponse(responseText);
}

function validateChatRequestBody(requestBody: ChatRequestBody): void {
  if (!requestBody.model?.trim()) {
    throw new Error("Missing chat model.");
  }

  if (!requestBody.system_prompt?.trim()) {
    throw new Error("Missing system prompt.");
  }

  if (!requestBody.user_prompt?.trim()) {
    throw new Error("Missing user prompt.");
  }
}

function resolveChatProvider(model: string): ChatProvider {
  if (model.startsWith("claude-")) {
    return "anthropic";
  }

  if (model.startsWith("gpt-")) {
    return "openai";
  }

  if (model.startsWith("gemini-")) {
    return "gemini";
  }

  throw new Error(`Unsupported chat model: ${model}`);
}

async function requestAnthropicChat(requestBody: ChatRequestBody, env: Env): Promise<string> {
  const messages: Array<Record<string, unknown>> = [];

  for (const conversationTurn of requestBody.conversation_history ?? []) {
    messages.push({
      role: "user",
      content: conversationTurn.user_transcript,
    });
    messages.push({
      role: "assistant",
      content: conversationTurn.assistant_response,
    });
  }

  const currentContentBlocks: Array<Record<string, unknown>> = [];

  for (const image of requestBody.images ?? []) {
    currentContentBlocks.push({
      type: "image",
      source: {
        type: "base64",
        media_type: image.media_type,
        data: image.data,
      },
    });
    currentContentBlocks.push({
      type: "text",
      text: image.label,
    });
  }

  currentContentBlocks.push({
    type: "text",
    text: requestBody.user_prompt,
  });

  messages.push({
    role: "user",
    content: currentContentBlocks,
  });

  const response = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "x-api-key": env.ANTHROPIC_API_KEY,
      "anthropic-version": "2023-06-01",
      "content-type": "application/json",
    },
    body: JSON.stringify({
      model: requestBody.model,
      max_tokens: 1024,
      system: requestBody.system_prompt,
      messages,
    }),
  });

  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/chat] Anthropic API error ${response.status}: ${errorBody}`);
    throw new Error(`Anthropic API error ${response.status}: ${errorBody}`);
  }

  const responseJson = (await response.json()) as {
    content?: Array<{ type?: string; text?: string }>;
  };

  const responseText = (responseJson.content ?? [])
    .filter((contentBlock) => contentBlock.type === "text")
    .map((contentBlock) => contentBlock.text ?? "")
    .join("");

  return responseText.trim();
}

async function requestOpenAIChat(requestBody: ChatRequestBody, env: Env): Promise<string> {
  const input: Array<Record<string, unknown>> = [
    {
      role: "system",
      content: [
        {
          type: "input_text",
          text: requestBody.system_prompt,
        },
      ],
    },
  ];

  for (const conversationTurn of requestBody.conversation_history ?? []) {
    input.push({
      role: "user",
      content: [
        {
          type: "input_text",
          text: conversationTurn.user_transcript,
        },
      ],
    });
    input.push({
      role: "assistant",
      content: [
        {
          type: "input_text",
          text: conversationTurn.assistant_response,
        },
      ],
    });
  }

  const currentContentBlocks: Array<Record<string, unknown>> = [];

  for (const image of requestBody.images ?? []) {
    currentContentBlocks.push({
      type: "input_text",
      text: image.label,
    });
    currentContentBlocks.push({
      type: "input_image",
      image_url: `data:${image.media_type};base64,${image.data}`,
    });
  }

  currentContentBlocks.push({
    type: "input_text",
    text: requestBody.user_prompt,
  });

  input.push({
    role: "user",
    content: currentContentBlocks,
  });

  const response = await fetch("https://api.openai.com/v1/responses", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${env.OPENAI_API_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model: requestBody.model,
      input,
      max_output_tokens: 1024,
    }),
  });

  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/chat] OpenAI API error ${response.status}: ${errorBody}`);
    throw new Error(`OpenAI API error ${response.status}: ${errorBody}`);
  }

  const responseJson = (await response.json()) as {
    output_text?: string;
    output?: Array<{
      content?: Array<{ type?: string; text?: string }>;
    }>;
  };

  if (responseJson.output_text?.trim()) {
    return responseJson.output_text.trim();
  }

  const responseText = (responseJson.output ?? [])
    .flatMap((outputItem) => outputItem.content ?? [])
    .filter((contentItem) => contentItem.type === "output_text")
    .map((contentItem) => contentItem.text ?? "")
    .join("");

  return responseText.trim();
}

async function requestGeminiChat(requestBody: ChatRequestBody, env: Env): Promise<string> {
  const contents: Array<Record<string, unknown>> = [];

  for (const conversationTurn of requestBody.conversation_history ?? []) {
    contents.push({
      role: "user",
      parts: [
        {
          text: conversationTurn.user_transcript,
        },
      ],
    });
    contents.push({
      role: "model",
      parts: [
        {
          text: conversationTurn.assistant_response,
        },
      ],
    });
  }

  const currentParts: Array<Record<string, unknown>> = [];

  for (const image of requestBody.images ?? []) {
    currentParts.push({
      text: image.label,
    });
    currentParts.push({
      inline_data: {
        mime_type: image.media_type,
        data: image.data,
      },
    });
  }

  currentParts.push({
    text: requestBody.user_prompt,
  });

  contents.push({
    role: "user",
    parts: currentParts,
  });

  const response = await fetch(
    `https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(requestBody.model)}:generateContent`,
    {
      method: "POST",
      headers: {
        "x-goog-api-key": env.GEMINI_API_KEY,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        system_instruction: {
          parts: [
            {
              text: requestBody.system_prompt,
            },
          ],
        },
        contents,
      }),
    }
  );

  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/chat] Gemini API error ${response.status}: ${errorBody}`);
    throw new Error(`Gemini API error ${response.status}: ${errorBody}`);
  }

  const responseJson = (await response.json()) as {
    candidates?: Array<{
      content?: {
        parts?: Array<{ text?: string }>;
      };
    }>;
  };

  const responseText = (responseJson.candidates ?? [])
    .flatMap((candidate) => candidate.content?.parts ?? [])
    .map((part) => part.text ?? "")
    .join("");

  return responseText.trim();
}

function makeNormalizedSSEResponse(responseText: string): Response {
  const encoder = new TextEncoder();
  const normalizedChunk = JSON.stringify({
    type: "content_block_delta",
    delta: {
      type: "text_delta",
      text: responseText,
    },
  });

  const stream = new ReadableStream<Uint8Array>({
    start(controller) {
      controller.enqueue(encoder.encode(`data: ${normalizedChunk}\n\n`));
      controller.enqueue(encoder.encode("data: [DONE]\n\n"));
      controller.close();
    },
  });

  return new Response(stream, {
    status: 200,
    headers: {
      "content-type": "text/event-stream; charset=utf-8",
      "cache-control": "no-cache",
      connection: "keep-alive",
    },
  });
}

async function handleTranscribeToken(env: Env): Promise<Response> {
  const response = await fetch(
    "https://streaming.assemblyai.com/v3/token?expires_in_seconds=480",
    {
      method: "GET",
      headers: {
        authorization: env.ASSEMBLYAI_API_KEY,
      },
    }
  );

  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/transcribe-token] AssemblyAI token error ${response.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: response.status,
      headers: { "content-type": "application/json" },
    });
  }

  const data = await response.text();
  return new Response(data, {
    status: 200,
    headers: { "content-type": "application/json" },
  });
}

async function handleTTS(request: Request, env: Env): Promise<Response> {
  const body = await request.text();
  const voiceId = env.ELEVENLABS_VOICE_ID;

  const response = await fetch(`https://api.elevenlabs.io/v1/text-to-speech/${voiceId}`, {
    method: "POST",
    headers: {
      "xi-api-key": env.ELEVENLABS_API_KEY,
      "content-type": "application/json",
      accept: "audio/mpeg",
    },
    body,
  });

  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/tts] ElevenLabs API error ${response.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: response.status,
      headers: { "content-type": "application/json" },
    });
  }

  return new Response(response.body, {
    status: response.status,
    headers: {
      "content-type": response.headers.get("content-type") || "audio/mpeg",
    },
  });
}
