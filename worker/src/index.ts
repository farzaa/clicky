/**
 * Clicky Proxy Worker
 *
 * Proxies requests to AI providers and ElevenLabs APIs so the app never
 * ships with raw API keys. Keys are stored as Cloudflare secrets.
 *
 * Routes:
 *   POST /chat  → Anthropic Messages API or Gemini API (streaming)
 *   POST /tts   → ElevenLabs TTS API
 */

interface Env {
  ANTHROPIC_API_KEY: string;
  GEMINI_API_KEY?: string;
  ELEVENLABS_API_KEY: string;
  ELEVENLABS_VOICE_ID: string;
  ASSEMBLYAI_API_KEY: string;
}

interface ChatRequest {
  model?: string;
  max_tokens?: number;
  stream?: boolean;
  system?: string;
  messages?: ChatMessage[];
}

interface ChatMessage {
  role: "user" | "assistant";
  content: string | ChatContentBlock[];
}

interface ChatContentBlock {
  type?: string;
  text?: string;
  source?: {
    media_type?: string;
    data?: string;
  };
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

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
      return new Response(
        JSON.stringify({ error: String(error) }),
        { status: 500, headers: { "content-type": "application/json" } }
      );
    }

    return new Response("Not found", { status: 404 });
  },
};

async function handleChat(request: Request, env: Env): Promise<Response> {
  const body = await request.json() as ChatRequest;

  if (body.model?.startsWith("gemini-")) {
    return await handleGeminiChat(body, env);
  }

  return await handleAnthropicChat(body, env);
}

async function handleAnthropicChat(body: ChatRequest, env: Env): Promise<Response> {
  const response = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "x-api-key": env.ANTHROPIC_API_KEY,
      "anthropic-version": "2023-06-01",
      "content-type": "application/json",
    },
    body: JSON.stringify(body),
  });

  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/chat] Anthropic API error ${response.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: response.status,
      headers: { "content-type": "application/json" },
    });
  }

  return new Response(response.body, {
    status: response.status,
    headers: {
      "content-type": response.headers.get("content-type") || "text/event-stream",
      "cache-control": "no-cache",
    },
  });
}

async function handleGeminiChat(body: ChatRequest, env: Env): Promise<Response> {
  if (!env.GEMINI_API_KEY) {
    return new Response(
      JSON.stringify({ error: "GEMINI_API_KEY is not configured" }),
      { status: 500, headers: { "content-type": "application/json" } }
    );
  }

  const model = body.model ?? "gemini-2.5-flash";
  const encodedModel = encodeURIComponent(model);
  const geminiBody = buildGeminiRequestBody(body);
  const methodName = body.stream ? "streamGenerateContent" : "generateContent";
  const searchParams = body.stream ? "?alt=sse" : "";

  const response = await fetch(
    `https://generativelanguage.googleapis.com/v1beta/models/${encodedModel}:${methodName}${searchParams}`,
    {
      method: "POST",
      headers: {
        "x-goog-api-key": env.GEMINI_API_KEY,
        "content-type": "application/json",
      },
      body: JSON.stringify(geminiBody),
    }
  );

  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/chat] Gemini API error ${response.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: response.status,
      headers: { "content-type": "application/json" },
    });
  }

  if (body.stream) {
    return streamGeminiResponseAsAnthropic(response);
  }

  const responseBody = await response.json() as GeminiGenerateContentResponse;
  const text = extractGeminiText(responseBody);

  return new Response(
    JSON.stringify({
      content: [
        {
          type: "text",
          text,
        },
      ],
    }),
    {
      status: 200,
      headers: { "content-type": "application/json" },
    }
  );
}

function buildGeminiRequestBody(body: ChatRequest): Record<string, unknown> {
  const contents = (body.messages ?? [])
    .map((message) => ({
      role: message.role === "assistant" ? "model" : "user",
      parts: buildGeminiParts(message.content),
    }))
    .filter((message) => message.parts.length > 0);

  const geminiBody: Record<string, unknown> = {
    contents,
    generationConfig: {
      maxOutputTokens: body.max_tokens ?? 1024,
    },
  };

  if (body.system) {
    geminiBody.systemInstruction = {
      parts: [{ text: body.system }],
    };
  }

  return geminiBody;
}

function buildGeminiParts(content: string | ChatContentBlock[]): Record<string, unknown>[] {
  if (typeof content === "string") {
    return [{ text: content }];
  }

  return content.flatMap((block): Record<string, unknown>[] => {
    if (block.type === "text" && block.text) {
      return [{ text: block.text }];
    }

    if (block.type === "image" && block.source?.data && block.source.media_type) {
      return [{
        inline_data: {
          mime_type: block.source.media_type,
          data: block.source.data,
        },
      }];
    }

    return [];
  });
}

interface GeminiGenerateContentResponse {
  candidates?: Array<{
    content?: {
      parts?: Array<{
        text?: string;
      }>;
    };
  }>;
}

function extractGeminiText(responseBody: GeminiGenerateContentResponse): string {
  return responseBody.candidates?.[0]?.content?.parts
    ?.map((part) => part.text ?? "")
    .join("") ?? "";
}

function streamGeminiResponseAsAnthropic(response: Response): Response {
  const responseBody = response.body;

  if (!responseBody) {
    return new Response(null, {
      status: 204,
      headers: { "content-type": "text/event-stream" },
    });
  }

  const encoder = new TextEncoder();
  const decoder = new TextDecoder();
  const reader = responseBody.getReader();
  const stream = new ReadableStream({
    async start(controller) {
      let bufferedText = "";

      try {
        while (true) {
          const { value, done } = await reader.read();
          if (done) {
            break;
          }

          bufferedText += decoder.decode(value, { stream: true });
          const lines = bufferedText.split("\n");
          bufferedText = lines.pop() ?? "";

          for (const line of lines) {
            enqueueGeminiLineAsAnthropicEvent(line, controller, encoder);
          }
        }

        if (bufferedText) {
          enqueueGeminiLineAsAnthropicEvent(bufferedText, controller, encoder);
        }

        controller.enqueue(encoder.encode(`data: ${JSON.stringify({ type: "message_stop" })}\n\n`));
        controller.close();
      } catch (error) {
        controller.error(error);
      } finally {
        reader.releaseLock();
      }
    },
  });

  return new Response(stream, {
    status: 200,
    headers: {
      "content-type": "text/event-stream",
      "cache-control": "no-cache",
    },
  });
}

function enqueueGeminiLineAsAnthropicEvent(
  line: string,
  controller: ReadableStreamDefaultController<Uint8Array>,
  encoder: TextEncoder
) {
  const trimmedLine = line.trim();
  if (!trimmedLine.startsWith("data: ")) {
    return;
  }

  const jsonString = trimmedLine.slice("data: ".length);
  if (!jsonString || jsonString === "[DONE]") {
    return;
  }

  let responseBody: GeminiGenerateContentResponse;
  try {
    responseBody = JSON.parse(jsonString) as GeminiGenerateContentResponse;
  } catch {
    return;
  }

  const text = extractGeminiText(responseBody);
  if (!text) {
    return;
  }

  controller.enqueue(encoder.encode(`data: ${JSON.stringify({
    type: "content_block_delta",
    delta: {
      type: "text_delta",
      text,
    },
  })}\n\n`));
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

  const response = await fetch(
    `https://api.elevenlabs.io/v1/text-to-speech/${voiceId}`,
    {
      method: "POST",
      headers: {
        "xi-api-key": env.ELEVENLABS_API_KEY,
        "content-type": "application/json",
        accept: "audio/mpeg",
      },
      body,
    }
  );

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
