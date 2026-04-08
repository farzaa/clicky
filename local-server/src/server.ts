/**
 * Clicky Local Server
 *
 * Replaces the Cloudflare Worker proxy with a local Node.js server
 * that uses the Claude Agent SDK. Authentication is inherited from the
 * locally installed Claude Code CLI session — no API key needed.
 *
 * Routes:
 *   POST /chat  → Claude via Agent SDK (streaming SSE)
 *
 * The app sends the same request body format it used with the Anthropic
 * API (model, system, messages with image content blocks, stream: true).
 * This server translates that into an Agent SDK query() call and streams
 * the response back as SSE in the same format the app already parses.
 */

import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { homedir } from "node:os";
import { existsSync } from "node:fs";
import { join } from "node:path";
import { query, type SDKUserMessage } from "@anthropic-ai/claude-agent-sdk";

const PORT = 3456;

// ---------------------------------------------------------------------------
// Claude binary discovery
// ---------------------------------------------------------------------------

function findClaudeBinaryPath(): string {
  const candidates = [
    join(homedir(), ".local", "bin", "claude"),
    "/usr/local/bin/claude",
    "/opt/homebrew/bin/claude",
  ];

  for (const candidate of candidates) {
    if (existsSync(candidate)) {
      return candidate;
    }
  }

  // Fall back to bare "claude" and hope it's on PATH
  return "claude";
}

const claudeBinaryPath = findClaudeBinaryPath();
console.log(`[clicky-server] Claude binary: ${claudeBinaryPath}`);

// ---------------------------------------------------------------------------
// Session management — keyed by model so switching models starts fresh
// ---------------------------------------------------------------------------

let currentSessionId: string | undefined;
let currentSessionModel: string | undefined;

// ---------------------------------------------------------------------------
// Request body types (matches what ClaudeAPI.swift sends)
// ---------------------------------------------------------------------------

interface ChatRequestBody {
  model: string;
  max_tokens: number;
  stream: boolean;
  system: string;
  messages: Array<{
    role: "user" | "assistant";
    content: string | Array<ContentBlock>;
  }>;
}

interface ContentBlock {
  type: "text" | "image";
  text?: string;
  source?: {
    type: "base64";
    media_type: string;
    data: string;
  };
}

// ---------------------------------------------------------------------------
// Read full request body as JSON
// ---------------------------------------------------------------------------

async function readRequestBody(req: IncomingMessage): Promise<ChatRequestBody> {
  const chunks: Buffer[] = [];
  for await (const chunk of req) {
    chunks.push(chunk as Buffer);
  }
  return JSON.parse(Buffer.concat(chunks).toString());
}

// ---------------------------------------------------------------------------
// Extract the last user message content blocks from the Anthropic-format
// messages array. The app sends conversation history as plain text messages
// followed by the current message with image content blocks.
// ---------------------------------------------------------------------------

function extractLastUserContent(body: ChatRequestBody): Array<ContentBlock> {
  // Find the last user message — that's the current turn with images
  for (let i = body.messages.length - 1; i >= 0; i--) {
    const message = body.messages[i];
    if (message.role === "user" && Array.isArray(message.content)) {
      return message.content;
    }
  }

  // Fallback: last user message is a plain string
  const lastUserMessage = body.messages.findLast((m) => m.role === "user");
  if (lastUserMessage) {
    const content = typeof lastUserMessage.content === "string"
      ? lastUserMessage.content
      : "Hello";
    return [{ type: "text", text: content }];
  }

  return [{ type: "text", text: "Hello" }];
}

// ---------------------------------------------------------------------------
// POST /chat handler — translates Anthropic API format to Agent SDK query()
// ---------------------------------------------------------------------------

async function handleChat(req: IncomingMessage, res: ServerResponse): Promise<void> {
  let body: ChatRequestBody;
  try {
    body = await readRequestBody(req);
  } catch (parseError) {
    console.error(`[/chat] Failed to parse request body:`, parseError);
    res.writeHead(400, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ error: "Invalid request body" }));
    return;
  }

  // If model changed, reset session so system prompt is re-sent
  if (body.model !== currentSessionModel) {
    currentSessionId = undefined;
    currentSessionModel = body.model;
  }

  // Build SDKUserMessage content from the last user message in the array
  const contentBlocks = extractLastUserContent(body);

  // Convert to Anthropic SDK MessageParam content format
  const sdkContent: Array<Record<string, unknown>> = [];
  for (const block of contentBlocks) {
    if (block.type === "image" && block.source) {
      sdkContent.push({
        type: "image",
        source: {
          type: "base64",
          media_type: block.source.media_type,
          data: block.source.data,
        },
      });
    } else if (block.type === "text" && block.text) {
      sdkContent.push({ type: "text", text: block.text });
    }
  }

  const userMessage: SDKUserMessage = {
    type: "user",
    session_id: currentSessionId ?? "",
    parent_tool_use_id: null,
    message: {
      role: "user",
      content: sdkContent as any,
    },
  };

  // Set up SSE response headers to match what ClaudeAPI.swift expects
  res.writeHead(200, {
    "Content-Type": "text/event-stream",
    "Cache-Control": "no-cache",
    Connection: "keep-alive",
  });

  const abortController = new AbortController();
  let requestCompleted = false;

  // Only abort the Claude process if the client disconnects while a
  // request is still in flight. After the response finishes, a close
  // event is expected and should not trigger an abort.
  req.on("close", () => {
    if (!requestCompleted) {
      console.log("[/chat] Client disconnected — aborting in-flight request");
      abortController.abort();
    }
  });

  // Build query options
  const isNewSession = !currentSessionId;
  const queryOptions: Record<string, unknown> = {
    model: body.model,
    includePartialMessages: true,
    maxTurns: 1,
    allowedTools: [],
    settingSources: [],
    abortController,
    pathToClaudeCodeExecutable: claudeBinaryPath,
    permissionMode: "bypassPermissions",
    allowDangerouslySkipPermissions: true,
  };

  // Only send system prompt on new sessions — resumed sessions remember it
  if (isNewSession) {
    queryOptions.systemPrompt = body.system;
  } else {
    queryOptions.resume = currentSessionId;
  }

  try {
    // Pass the user message as an async iterable (the pattern T3 Code uses).
    // The SDK expects AsyncIterable<SDKUserMessage> for structured content.
    async function* generatePrompt(): AsyncGenerator<SDKUserMessage> {
      yield userMessage;
    }

    const queryResult = query({
      prompt: generatePrompt(),
      options: queryOptions as any,
    });

    let fullResponseText: string[] = [];

    for await (const message of queryResult) {
      // Capture session ID from init event
      if (message.type === "system" && (message as any).subtype === "init") {
        currentSessionId = (message as any).session_id ?? currentSessionId;
        currentSessionModel = body.model;
      }

      // Collect streaming text deltas for progressive display
      if (message.type === "stream_event") {
        const event = (message as any).event;
        if (
          event?.type === "content_block_delta" &&
          event.delta?.type === "text_delta" &&
          event.delta?.text
        ) {
          fullResponseText.push(event.delta.text);
        }
      }

      // The complete assistant message is the authoritative response.
      // Use it instead of accumulated deltas to avoid truncation issues
      // where the [POINT:] tag gets split across chunks.
      if (message.type === "assistant") {
        const assistantMessage = message as any;
        const content = assistantMessage.message?.content;
        if (Array.isArray(content)) {
          // Replace any partial streaming text with the complete response
          fullResponseText.length = 0;
          for (const block of content) {
            if (block.type === "text" && block.text) {
              fullResponseText.push(block.text);
            }
          }
        }
      }

      // Update session ID from result
      if (message.type === "result") {
        const resultMessage = message as any;
        currentSessionId = resultMessage.session_id ?? currentSessionId;
        // Fallback: use result text if nothing else came through
        if (fullResponseText.length === 0 && resultMessage.result && typeof resultMessage.result === "string") {
          fullResponseText.push(resultMessage.result);
        }
      }
    }

    // Send the complete response as a single SSE event so the app
    // receives the full text including the [POINT:] tag intact.
    const completeText = fullResponseText.join("");
    if (completeText.length > 0) {
      const ssePayload = JSON.stringify({
        type: "content_block_delta",
        delta: { type: "text_delta", text: completeText },
      });
      res.write(`data: ${ssePayload}\n\n`);
    }
    console.log(`[/chat] Response complete: ${completeText.length} chars`);
  } catch (error: unknown) {
    // Suppress abort errors from client disconnects — these are expected
    const errorMessage = String(error);
    const isAbortError = errorMessage.includes("aborted by user") ||
      errorMessage.includes("AbortError") ||
      abortController.signal.aborted;

    if (!isAbortError) {
      console.error("[/chat] Agent SDK error:", error);
      const errorPayload = JSON.stringify({ error: errorMessage });
      res.write(`data: ${errorPayload}\n\n`);
    }
  }

  requestCompleted = true;

  // Send the same end marker the Anthropic API sends
  if (!abortController.signal.aborted) {
    res.write("data: [DONE]\n\n");
  }
  res.end();
}

// ---------------------------------------------------------------------------
// HTTP server
// ---------------------------------------------------------------------------

const server = createServer(async (req, res) => {
  // CORS headers for local development
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Methods", "POST, OPTIONS");
  res.setHeader("Access-Control-Allow-Headers", "Content-Type");

  if (req.method === "OPTIONS") {
    res.writeHead(204);
    res.end();
    return;
  }

  if (req.method !== "POST") {
    res.writeHead(405);
    res.end("Method not allowed");
    return;
  }

  const url = new URL(req.url ?? "/", `http://localhost:${PORT}`);

  if (url.pathname === "/chat") {
    await handleChat(req, res);
    return;
  }

  res.writeHead(404);
  res.end("Not found");
});

server.listen(PORT, () => {
  console.log(`[clicky-server] Listening on http://localhost:${PORT}`);
  console.log(`[clicky-server] POST /chat → Claude Agent SDK`);
  console.log(`[clicky-server] TTS and STT are handled natively by the app`);
});
