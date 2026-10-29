#!/usr/bin/env node
import http from "node:http";

const PORT = Number(process.env.MOCK_WORKER_PORT ?? 8787);

function jsonResponse(res, status, body) {
  res.writeHead(status, { "content-type": "application/json" });
  res.end(JSON.stringify(body));
}

function streamVoiceResponse(res) {
  const text =
    "click file then save, or use command s. [POINT:120,40:file menu]";
  const chunks = text.match(/.{1,12}/g) ?? [text];

  res.writeHead(200, {
    "content-type": "text/event-stream",
    "cache-control": "no-cache",
  });

  for (const chunk of chunks) {
    const payload = {
      type: "content_block_delta",
      delta: { type: "text_delta", text: chunk },
    };
    res.write(`data: ${JSON.stringify(payload)}\n\n`);
  }
  res.write("data: [DONE]\n\n");
  res.end();
}

function synthesisResponse(res, parsed) {
  const messages = parsed.messages ?? [];
  const lastMessage = messages.at(-1) ?? {};
  const content = lastMessage.content;
  const promptText = typeof content === "string"
    ? content
    : Array.isArray(content)
      ? content.map((part) => part.text ?? "").join("\n")
      : "";
  const isPatch = promptText.includes("patch this existing teaching skill");

  const text = isPatch
    ? [
        "workflow: save a document in textedit",
        "preference: keyboard shortcut only, avoid the file menu",
        "step one: press command s to save",
        "pointing: do not point at the file menu unless the user asks for menu steps",
        "completion: user says got it or thanks that worked",
      ].join("\n")
    : [
        "workflow: save a document in textedit",
        "step one: click file in the menu bar",
        "step two: choose save or press command s",
        "pointing: start at the file menu near the top left",
        "common mistake: looking for a floppy disk icon instead of file > save",
        "completion: user says got it or thanks that worked",
      ].join("\n");

  jsonResponse(res, 200, {
    content: [
      {
        type: "text",
        text,
      },
    ],
  });
}

const server = http.createServer(async (req, res) => {
  if (req.method !== "POST") {
    res.writeHead(405);
    res.end("Method not allowed");
    return;
  }

  const body = await new Promise((resolve, reject) => {
    const chunks = [];
    req.on("data", (chunk) => chunks.push(chunk));
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    req.on("error", reject);
  });

  if (req.url === "/tts") {
    res.writeHead(200, { "content-type": "audio/mpeg" });
    res.end(Buffer.from([0xff, 0xfb, 0x90, 0x00]));
    return;
  }

  if (req.url === "/chat") {
    let parsed = {};
    try {
      parsed = JSON.parse(body);
    } catch {
      res.writeHead(400);
      res.end("invalid json");
      return;
    }

    if (parsed.stream === true) {
      streamVoiceResponse(res);
      return;
    }

    synthesisResponse(res, parsed);
    return;
  }

  res.writeHead(404);
  res.end("Not found");
});

server.listen(PORT, "127.0.0.1", () => {
  console.log(`mock worker listening on http://127.0.0.1:${PORT}`);
});
