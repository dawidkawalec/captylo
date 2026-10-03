import { Hono, type Context } from "hono";
import type { AppEnv, Deps } from "../app.js";
import { readJsonObject, smallBody } from "../lib/http.js";
import { userHash } from "../lib/ids.js";
import type { LogFields } from "../lib/log.js";
import { addUsage, nextMonthStart, overAudioCap, overTokenCap, usageFor } from "../lib/usage.js";
import { requirePro } from "../middleware/pro.js";
import { requireSession } from "../middleware/session.js";

/** A chat request is text only; 2 MB is far more than any meeting transcript the app sends. */
export const CHAT_MAX_BYTES = 2 * 1024 * 1024;
/** The upload limit, the same as Caddy's `request_body max_size 220MB` in front of the service. */
export const STT_MAX_BYTES = 220_000_000;
/** The longest audio one request may declare: 4 hours. */
export const STT_MAX_SECONDS = 4 * 60 * 60;
/**
 * Uploads one account may run at a time. The month's cap is checked before the vendor call, so
 * every upload running in parallel could pass it; this bounds how far past the cap they go.
 */
export const STT_MAX_IN_FLIGHT = 3;
/** Faster than anyone speaks (about 15 characters a second): text length / this is a floor for the audio's length. */
const MAX_CHARS_PER_SECOND = 25;

const CHAT_TIMEOUT_MS = 5 * 60_000;
/** Caddy's `read_timeout 15m` ends the request anyway; the vendor call stops with it. */
const STT_TIMEOUT_MS = 15 * 60_000;
/** A server-sent event line longer than this is content, never the usage chunk; it is not kept. */
const MAX_SSE_LINE = 64 * 1024;

type Route = "chat" | "stt";

/**
 * The relay for Pro accounts, with the server's keys:
 * - `POST /v1/chat/completions`: the app's chat body with the model replaced by `PRO_AI_MODEL`
 *   and only the fields the app uses, to the AI vendor; tokens counted from the vendor's
 *   `usage` (or estimated from the bytes);
 * - `POST /v1/speech-to-text`: the app's multipart upload streamed to the speech-to-text
 *   vendor unchanged; seconds counted as the larger of `X-Captylo-Audio-Seconds` and what the
 *   vendor's answer shows was transcribed (the client's header alone can be forged); at most
 *   `STT_MAX_IN_FLIGHT` uploads per account at a time (429 `too_many_requests`).
 * Both need a session (401) and Pro (403 `pro_required`); over the month's cap they answer
 * 402 `quota_exceeded` with `resetsAt` before the vendor is called. Vendor errors become
 * generic codes, never the vendor's text. Nothing of the audio or the text is stored or logged.
 */
export function relayRoutes(deps: Deps): Hono<AppEnv> {
  const routes = new Hono<AppEnv>();
  const session = requireSession(deps);
  const pro = requirePro(deps);
  /** Uploads running per account (one instance, like the rate limiter). */
  const sttInFlight = new Map<string, number>();

  routes.post("/chat/completions", session, pro, smallBody(CHAT_MAX_BYTES), async (c) => {
    const started = performance.now();
    const user = c.get("user");
    const done = (status: number, fields: LogFields = {}) => logRelay(deps, c, "chat", user.id, status, started, fields);
    if (!deps.config.openRouterKey) return unavailable(c, deps, "chat");

    const body = await readJsonObject(c);
    const forwarded = body ? chatBody(body, deps.config.proAiModel) : undefined;
    if (!forwarded) return c.json({ error: "bad_request" }, 400);

    const now = deps.now();
    if (overTokenCap(await usageFor(deps.db, user.id, now), deps.config.proAiTokensPerMonth)) {
      done(402);
      return quotaExceeded(c, now);
    }

    const requestText = JSON.stringify(forwarded);
    const requestBytes = Buffer.byteLength(requestText);
    let res: Response;
    try {
      res = await deps.fetchUpstream(`${deps.config.openRouterBaseUrl}/chat/completions`, {
        method: "POST",
        headers: {
          Authorization: `Bearer ${deps.config.openRouterKey}`,
          "Content-Type": "application/json",
          "HTTP-Referer": "https://captylo.com",
          "X-Title": "Captylo",
        },
        body: requestText,
        signal: deadline(c, CHAT_TIMEOUT_MS),
      });
    } catch (error) {
      done(502, { failure: errorName(error) });
      return c.json({ error: "upstream_failed" }, 502);
    }
    if (!res.ok) return upstreamError(c, res, "chat", done);

    const contentType = res.headers.get("Content-Type") ?? "application/json";
    if (forwarded.stream === true && res.body) {
      const stream = meteredStream(res.body, async (bytes, reported) => {
        const tokens = reported ?? estimateTokens(requestBytes + bytes);
        try {
          await addUsage(deps.db, user.id, deps.now(), { aiTokens: tokens });
          done(res.status, { tokens, estimated: reported === undefined, stream: true });
        } catch (error) {
          done(res.status, { failure: `usage:${errorName(error)}`, stream: true });
        }
      });
      return new Response(stream, { status: res.status, headers: { "Content-Type": contentType, "Cache-Control": "no-cache" } });
    }

    let answer: ArrayBuffer;
    try {
      answer = await res.arrayBuffer();
    } catch (error) {
      done(502, { failure: errorName(error) });
      return c.json({ error: "upstream_failed" }, 502);
    }
    const reported = totalTokens(parseJson(new TextDecoder().decode(answer)));
    const tokens = reported ?? estimateTokens(requestBytes + answer.byteLength);
    await addUsage(deps.db, user.id, deps.now(), { aiTokens: tokens });
    done(res.status, { tokens, estimated: reported === undefined });
    return new Response(answer, { status: res.status, headers: { "Content-Type": contentType } });
  });

  routes.post("/speech-to-text", session, pro, async (c) => {
    const started = performance.now();
    const user = c.get("user");
    const done = (status: number, fields: LogFields = {}) => logRelay(deps, c, "stt", user.id, status, started, fields);
    if (!deps.config.sttKey) return unavailable(c, deps, "stt");

    const seconds = audioSeconds(c.req.header("X-Captylo-Audio-Seconds"));
    const contentType = c.req.header("Content-Type") ?? "";
    const body = c.req.raw.body;
    if (seconds === undefined || !/^multipart\/form-data;\s*boundary=/i.test(contentType) || !body) {
      return c.json({ error: "bad_request" }, 400);
    }
    const declared = c.req.header("Content-Length");
    const length = declared !== undefined && /^\d+$/.test(declared) ? Number(declared) : undefined;
    if (length !== undefined && length > STT_MAX_BYTES) return c.json({ error: "too_large" }, 413);

    const running = sttInFlight.get(user.id) ?? 0;
    if (running >= STT_MAX_IN_FLIGHT) {
      done(429, { seconds, inFlight: running });
      return c.json({ error: "too_many_requests" }, 429);
    }
    sttInFlight.set(user.id, running + 1);
    try {
      return await relaySpeech(c, seconds, contentType, body, length, done);
    } finally {
      const left = (sttInFlight.get(user.id) ?? 1) - 1;
      if (left > 0) sttInFlight.set(user.id, left);
      else sttInFlight.delete(user.id);
    }
  });

  /** The speech-to-text call itself, once the request is valid and holds an upload slot. */
  async function relaySpeech(
    c: Context<AppEnv>,
    seconds: number,
    contentType: string,
    body: ReadableStream<Uint8Array>,
    length: number | undefined,
    done: (status: number, fields?: LogFields) => void,
  ): Promise<Response> {
    const user = c.get("user");
    const now = deps.now();
    const capSeconds = Math.floor(deps.config.proAudioHoursPerMonth * 3600);
    if (overAudioCap(await usageFor(deps.db, user.id, now), capSeconds, seconds)) {
      done(402, { seconds });
      return quotaExceeded(c, now);
    }

    const limited = limitStream(body, STT_MAX_BYTES);
    let res: Response;
    try {
      res = await deps.fetchUpstream(`${deps.config.sttBaseUrl}/speech-to-text`, {
        method: "POST",
        headers: {
          "xi-api-key": deps.config.sttKey,
          "Content-Type": contentType,
          Accept: "application/json",
          ...(length !== undefined ? { "Content-Length": String(length) } : {}),
        },
        body: limited.stream,
        duplex: "half",
        signal: deadline(c, STT_TIMEOUT_MS),
      } as RequestInit);
    } catch (error) {
      if (limited.exceeded()) {
        done(413, { seconds });
        return c.json({ error: "too_large" }, 413);
      }
      done(502, { failure: errorName(error) });
      return c.json({ error: "upstream_failed" }, 502);
    }
    if (!res.ok) return upstreamError(c, res, "stt", done);

    let answer: ArrayBuffer;
    try {
      answer = await res.arrayBuffer();
    } catch (error) {
      done(502, { failure: errorName(error) });
      return c.json({ error: "upstream_failed" }, 502);
    }
    const measured = measuredAudioSeconds(parseJson(new TextDecoder().decode(answer)));
    const counted = Math.max(seconds, measured ?? 0);
    await addUsage(deps.db, user.id, deps.now(), { audioSeconds: counted });
    done(res.status, { seconds: counted, declaredSeconds: seconds, ...(measured !== undefined ? { measuredSeconds: measured } : {}) });
    if (counted > seconds) {
      deps.log.warn({ reqId: c.get("reqId"), user: userHash(user.id), route: "stt", declaredSeconds: seconds, measuredSeconds: measured }, "stt seconds under-declared");
    }
    return new Response(answer, { status: res.status, headers: { "Content-Type": res.headers.get("Content-Type") ?? "application/json" } });
  }

  return routes;
}

/**
 * How much audio the vendor's answer shows was transcribed, in whole seconds: the latest word end
 * over every channel (`words`, or `transcripts[].words` for multichannel), and at least the
 * transcript's length read faster than anyone speaks (an answer without word times). Undefined
 * when the answer has neither. Only numbers are read, nothing is kept.
 */
export function measuredAudioSeconds(json: unknown): number | undefined {
  if (!isObject(json)) return undefined;
  const channels = Array.isArray(json.transcripts) ? json.transcripts.filter(isObject) : [json];
  let best: number | undefined;
  const consider = (value: number) => {
    if (Number.isFinite(value) && value > 0) best = Math.max(best ?? 0, Math.ceil(value));
  };
  for (const channel of channels) {
    if (Array.isArray(channel.words)) {
      for (const word of channel.words) {
        if (isObject(word) && typeof word.end === "number") consider(word.end);
      }
    }
    if (typeof channel.text === "string") consider(channel.text.length / MAX_CHARS_PER_SECOND);
  }
  return best;
}

/** The chat fields the app sends, as the vendor gets them: the server's model, nothing else added. */
interface ChatBody {
  model: string;
  messages: unknown[];
  temperature?: number;
  max_tokens?: number;
  reasoning?: Record<string, unknown>;
  provider?: { sort: string };
  stream?: boolean;
}

/**
 * The body sent upstream: the server's model and only the fields the app uses. Fields such as
 * `models` (fallback models), `plugins` (paid web search) or provider pinning are dropped, so
 * a Pro token cannot pick a pricier model or feature. Undefined when there are no messages.
 */
export function chatBody(body: Record<string, unknown>, model: string): ChatBody | undefined {
  const { messages, temperature, max_tokens: maxTokens, reasoning, provider, stream } = body;
  if (!Array.isArray(messages) || messages.length === 0) return undefined;
  const out: ChatBody = { model, messages };
  if (typeof temperature === "number") out.temperature = temperature;
  if (typeof maxTokens === "number") out.max_tokens = maxTokens;
  if (isObject(reasoning)) out.reasoning = reasoning;
  if (isObject(provider) && typeof provider.sort === "string") out.provider = { sort: provider.sort };
  if (typeof stream === "boolean") out.stream = stream;
  return out;
}

/** `X-Captylo-Audio-Seconds`: a whole number from 1 to 4 hours, else undefined. */
function audioSeconds(header: string | undefined): number | undefined {
  if (header === undefined || !/^\d{1,6}$/.test(header.trim())) return undefined;
  const value = Number(header.trim());
  return value >= 1 && value <= STT_MAX_SECONDS ? value : undefined;
}

/**
 * Passes `source` through and errors it once more than `maxBytes` went by, so an upload
 * without a Content-Length is cut off without ever being held in memory.
 */
export function limitStream(source: ReadableStream<Uint8Array>, maxBytes: number): { stream: ReadableStream<Uint8Array>; exceeded: () => boolean } {
  let seen = 0;
  let over = false;
  const stream = source.pipeThrough(
    new TransformStream<Uint8Array, Uint8Array>({
      transform(chunk, controller) {
        seen += chunk.byteLength;
        if (seen > maxBytes) {
          over = true;
          controller.error(new RangeError("upload over the size limit"));
          return;
        }
        controller.enqueue(chunk);
      },
    }),
  );
  return { stream, exceeded: () => over };
}

/** `usage.total_tokens` of one server-sent event line (`data: {...}`), else undefined. */
export function tokensFromSse(line: string): number | undefined {
  if (!line.startsWith("data:")) return undefined;
  const payload = line.slice(5).trim();
  if (!payload.includes("usage")) return undefined;
  return totalTokens(parseJson(payload));
}

/**
 * Passes the vendor's event stream through chunk by chunk and, when it ends (or the app
 * cancels it), calls `onEnd` with the bytes seen and the tokens of the last usage chunk.
 * Only the current, unfinished line is kept, never the whole answer.
 */
function meteredStream(source: ReadableStream<Uint8Array>, onEnd: (bytes: number, tokens: number | undefined) => Promise<void>): ReadableStream<Uint8Array> {
  const reader = source.getReader();
  const decoder = new TextDecoder();
  let bytes = 0;
  let pending = "";
  let tokens: number | undefined;
  let ended = false;

  const scan = (text: string, final: boolean) => {
    pending += text;
    const lines = pending.split("\n");
    pending = final ? "" : (lines.pop() ?? "");
    for (const line of lines) {
      const found = tokensFromSse(line.trimEnd());
      if (found !== undefined) tokens = found;
    }
    if (pending.length > MAX_SSE_LINE) pending = "";
  };
  const finish = async () => {
    if (ended) return;
    ended = true;
    await onEnd(bytes, tokens);
  };

  return new ReadableStream<Uint8Array>({
    async pull(controller) {
      let chunk: Awaited<ReturnType<typeof reader.read>>;
      try {
        chunk = await reader.read();
      } catch (error) {
        await finish();
        controller.error(error);
        return;
      }
      if (chunk.done) {
        scan(decoder.decode(), true);
        await finish();
        controller.close();
        return;
      }
      bytes += chunk.value.byteLength;
      scan(decoder.decode(chunk.value, { stream: true }), false);
      controller.enqueue(chunk.value);
    },
    async cancel(reason) {
      await reader.cancel(reason).catch(() => undefined);
      await finish();
    },
  });
}

/**
 * A vendor error as a generic code: 429 stays 429 (`upstream_busy`), a rejected input is 400
 * (`upstream_rejected`, for speech 422 `bad_audio`), anything else, including our key being
 * refused, is 502 `upstream_failed`. The vendor's body is dropped unread.
 */
async function upstreamError(c: Context<AppEnv>, res: Response, route: Route, done: (status: number, fields?: LogFields) => void) {
  await res.body?.cancel().catch(() => undefined);
  let status: 400 | 422 | 429 | 502;
  let error: string;
  if (res.status === 429) {
    status = 429;
    error = "upstream_busy";
  } else if (route === "stt" && res.status === 422) {
    status = 422;
    error = "bad_audio";
  } else if (res.status === 400 || res.status === 413 || res.status === 422) {
    status = 400;
    error = "upstream_rejected";
  } else {
    status = 502;
    error = "upstream_failed";
  }
  done(status, { upstreamStatus: res.status });
  return c.json({ error }, status);
}

function quotaExceeded(c: Context<AppEnv>, now: Date) {
  return c.json({ error: "quota_exceeded", resetsAt: nextMonthStart(now).toISOString() }, 402);
}

function unavailable(c: Context<AppEnv>, deps: Deps, route: Route) {
  deps.log.error({ reqId: c.get("reqId"), route, reason: "key_not_configured" }, "relay not configured");
  return c.json({ error: "relay_unavailable" }, 503);
}

/** The relay's one log line per request: counts and a pseudonym of the account, nothing else. */
function logRelay(deps: Deps, c: Context<AppEnv>, route: Route, userId: string, status: number, started: number, fields: LogFields): void {
  deps.log.info({ reqId: c.get("reqId"), user: userHash(userId), route, status, ms: Math.round(performance.now() - started), ...fields });
}

/** Ends the vendor call when the app disconnects or the time is up. */
function deadline(c: Context<AppEnv>, ms: number): AbortSignal {
  return AbortSignal.any([c.req.raw.signal, AbortSignal.timeout(ms)]);
}

/** Rough tokens of a text of `bytes` bytes, used when the vendor reports none. */
function estimateTokens(bytes: number): number {
  return Math.ceil(bytes / 4);
}

function totalTokens(json: unknown): number | undefined {
  if (!isObject(json) || !isObject(json.usage)) return undefined;
  const total = json.usage.total_tokens;
  return typeof total === "number" && Number.isFinite(total) && total >= 0 ? total : undefined;
}

function parseJson(text: string): unknown {
  try {
    return JSON.parse(text);
  } catch {
    return undefined;
  }
}

function isObject(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function errorName(error: unknown): string {
  return error instanceof Error ? error.name : "unknown";
}
