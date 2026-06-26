import { HttpError } from "./http";

const decoder = new TextDecoder();

export async function readJSONRequest<T>(request: Request, maxBytes: number): Promise<T> {
  const rawBody = await readBoundedRequestText(request, maxBytes, "Request body is too large.");
  return parseJSONText<T>(rawBody, "Invalid JSON body.");
}

export async function readBoundedRequestText(
  request: Request,
  maxBytes: number,
  tooLargeMessage: string
): Promise<string> {
  return await readBoundedTextBody(request.headers, request.body, maxBytes, tooLargeMessage, 413);
}

export async function readBoundedResponseText(
  response: Response,
  maxBytes: number,
  tooLargeMessage: string
): Promise<string> {
  return await readBoundedTextBody(response.headers, response.body, maxBytes, tooLargeMessage, 502);
}

export function parseJSONText<T = unknown>(value: string, errorMessage: string, status = 400): T {
  try {
    return JSON.parse(value) as T;
  } catch {
    throw new HttpError(status, errorMessage);
  }
}

async function readBoundedTextBody(
  headers: Headers,
  stream: ReadableStream<Uint8Array> | null,
  maxBytes: number,
  tooLargeMessage: string,
  status: number
): Promise<string> {
  const contentLength = Number(headers.get("content-length"));
  if (Number.isFinite(contentLength) && contentLength > maxBytes) {
    throw new HttpError(status, tooLargeMessage);
  }

  if (!stream) {
    return "";
  }

  const reader = stream.getReader();
  const chunks: Uint8Array[] = [];
  let receivedBytes = 0;

  while (true) {
    const { done, value } = await reader.read();
    if (done) {
      break;
    }
    if (!value) {
      continue;
    }

    receivedBytes += value.byteLength;
    if (receivedBytes > maxBytes) {
      await reader.cancel();
      throw new HttpError(status, tooLargeMessage);
    }
    chunks.push(value);
  }

  const bytes = new Uint8Array(receivedBytes);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }

  return decoder.decode(bytes);
}
