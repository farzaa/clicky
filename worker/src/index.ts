/**
 * Clicky Proxy Worker
 *
 * Proxies requests to Claude and ElevenLabs APIs so the app never
 * ships with raw API keys. Keys are stored as Cloudflare secrets.
 *
 * Routes:
 *   POST /chat              → Anthropic Messages API (streaming, no tools)
 *   POST /chat-tools        → Anthropic Messages API + Composio tools (non-streaming, agentic loop)
 *   POST /tts               → ElevenLabs TTS API
 *   POST /transcribe-token  → AssemblyAI streaming token
 */

import Anthropic from "@anthropic-ai/sdk";
import { Composio } from "@composio/core";
import { AnthropicProvider } from "@composio/anthropic";

interface Env {
  ANTHROPIC_API_KEY: string;
  ELEVENLABS_API_KEY: string;
  ELEVENLABS_VOICE_ID: string;
  ASSEMBLYAI_API_KEY: string;
  COMPOSIO_API_KEY: string;
}

// Cap the agentic tool-call loop so a model that gets stuck calling tools
// in a cycle eventually returns control to the user.
const MAX_TOOL_LOOP_ITERATIONS = 5;

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

      if (url.pathname === "/chat-tools") {
        return await handleChatWithTools(request, env);
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
  const body = await request.text();

  const response = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "x-api-key": env.ANTHROPIC_API_KEY,
      "anthropic-version": "2023-06-01",
      "content-type": "application/json",
    },
    body,
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

/**
 * Tool-augmented chat. Same input shape as /chat (Anthropic Messages body)
 * with a required `x-clicky-user-id` header that identifies the Composio
 * session owner. Composio tools available to the user are injected into
 * the request, and the agentic loop runs server-side. Returns a single
 * non-streaming JSON response shaped like:
 *
 *   { "text": "<final assistant message>",
 *     "tool_calls": [{ "name": "...", "input": {...}, "result": {...} }, ...] }
 *
 * Non-streaming for v1 — Clicky's TTS pipeline buffers anyway, and mid-stream
 * tool execution adds a lot of complexity for marginal UX gain.
 */
async function handleChatWithTools(request: Request, env: Env): Promise<Response> {
  const clickyUserId = request.headers.get("x-clicky-user-id");
  if (!clickyUserId) {
    return new Response(
      JSON.stringify({ error: "Missing x-clicky-user-id header" }),
      { status: 400, headers: { "content-type": "application/json" } }
    );
  }

  if (!env.COMPOSIO_API_KEY) {
    return new Response(
      JSON.stringify({ error: "COMPOSIO_API_KEY is not configured on the worker" }),
      { status: 500, headers: { "content-type": "application/json" } }
    );
  }

  // The Swift app sends a fully-formed Anthropic Messages body. We deserialize
  // it, strip the `stream` flag (we run a non-streaming loop), and inject
  // Composio tools before sending to Anthropic.
  let incomingRequestBody: {
    model: string;
    max_tokens: number;
    system?: string;
    messages: Anthropic.MessageParam[];
    stream?: boolean;
  };
  try {
    incomingRequestBody = await request.json();
  } catch (parseError) {
    return new Response(
      JSON.stringify({ error: `Invalid JSON body: ${String(parseError)}` }),
      { status: 400, headers: { "content-type": "application/json" } }
    );
  }

  const composio = new Composio({
    apiKey: env.COMPOSIO_API_KEY,
    provider: new AnthropicProvider(),
  });

  const composioSession = await composio.create(clickyUserId);
  const composioTools = await composioSession.tools();

  const anthropicClient = new Anthropic({ apiKey: env.ANTHROPIC_API_KEY });

  const conversationMessages: Anthropic.MessageParam[] = [...incomingRequestBody.messages];
  const executedToolCalls: Array<{ name: string; input: unknown; result: unknown }> = [];

  let anthropicResponse = await anthropicClient.messages.create({
    model: incomingRequestBody.model,
    max_tokens: incomingRequestBody.max_tokens,
    system: incomingRequestBody.system,
    tools: composioTools,
    messages: conversationMessages,
  });

  let toolLoopIterationsRemaining = MAX_TOOL_LOOP_ITERATIONS;

  while (
    anthropicResponse.stop_reason === "tool_use" &&
    toolLoopIterationsRemaining > 0
  ) {
    toolLoopIterationsRemaining -= 1;

    // Record tool calls that Claude is asking us to execute, for transcript.
    for (const contentBlock of anthropicResponse.content) {
      if (contentBlock.type === "tool_use") {
        executedToolCalls.push({
          name: contentBlock.name,
          input: contentBlock.input,
          result: null,
        });
      }
    }

    // Composio executes the tool calls server-side using the user's connected
    // accounts and returns Anthropic-shaped tool_result message(s).
    const toolResultMessages = await composio.provider.handleToolCalls(
      clickyUserId,
      anthropicResponse
    );

    conversationMessages.push({ role: "assistant", content: anthropicResponse.content });
    for (const toolResultMessage of toolResultMessages) {
      conversationMessages.push(toolResultMessage);
    }

    // Backfill the result on the most recent N entries we appended.
    const numberOfToolUsesThisTurn = anthropicResponse.content.filter(
      (block) => block.type === "tool_use"
    ).length;
    for (
      let toolCallIndex = 0;
      toolCallIndex < numberOfToolUsesThisTurn;
      toolCallIndex += 1
    ) {
      const correspondingResultMessage = toolResultMessages[toolCallIndex];
      const indexInExecutedList =
        executedToolCalls.length - numberOfToolUsesThisTurn + toolCallIndex;
      if (executedToolCalls[indexInExecutedList]) {
        executedToolCalls[indexInExecutedList].result =
          correspondingResultMessage?.content ?? null;
      }
    }

    anthropicResponse = await anthropicClient.messages.create({
      model: incomingRequestBody.model,
      max_tokens: incomingRequestBody.max_tokens,
      system: incomingRequestBody.system,
      tools: composioTools,
      messages: conversationMessages,
    });
  }

  let finalAssistantText = "";
  for (const contentBlock of anthropicResponse.content) {
    if (contentBlock.type === "text") {
      finalAssistantText += contentBlock.text;
    }
  }

  if (toolLoopIterationsRemaining === 0 && anthropicResponse.stop_reason === "tool_use") {
    finalAssistantText +=
      "\n\n(Stopped after the maximum number of tool calls. Try asking again.)";
  }

  return new Response(
    JSON.stringify({
      text: finalAssistantText,
      tool_calls: executedToolCalls,
      stop_reason: anthropicResponse.stop_reason,
    }),
    {
      status: 200,
      headers: { "content-type": "application/json" },
    }
  );
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
