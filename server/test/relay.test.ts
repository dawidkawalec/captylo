import { randomBytes } from "node:crypto";
import { beforeEach, describe, expect, it } from "vitest";
import { buildApp } from "../src/app.js";
import { limitStream, tokensFromSse } from "../src/routes/relay.js";
import { addUsage, usageFor } from "../src/lib/usage.js";
import { signIn, testDeps, type TestDeps } from "./helpers.js";

const AI_KEY = "relay-ai-key-for-tests";
const STT_KEY = "relay-stt-key-for-tests";
const relayConfig = {
  OPENROUTER_API_KEY: AI_KEY,
  OPENROUTER_BASE_URL: "https://ai.upstream.test/api/v1",
  PRO_AI_MODEL: "server/picked-model",
  STT_API_KEY: STT_KEY,
  STT_BASE_URL: "https://stt.upstream.test/v1",
};

let deps: TestDeps;
let app: ReturnType<typeof buildApp>;

async function setUp(overrides: Record<string, string> = {}): Promise<void> {
  deps = await testDeps({ ...relayConfig, ...overrides });
  app = buildApp(deps);
}

beforeEach(async () => {
  await setUp();
});

async function userId(email: string): Promise<string> {
  const row = await deps.db.one<{ id: string }>("select id from users where email = $1", [email]);
  if (!row) throw new Error("no such user");
  return row.id;
}

/** Signs `email` in and, unless `free`, gives the account an active yearly subscription. */
async function account(email = "anna@example.pl", plan: "pro" | "free" = "pro"): Promise<{ token: string; id: string }> {
  const token = await signIn(app, deps.mailer, email);
  const id = await userId(email);
  if (plan === "pro") {
    await deps.db.query(
      `insert into subscriptions (user_id, stripe_subscription_id, status, plan, current_period_start, current_period_end, cancel_at_period_end, event_created)
       values ($1, $2, 'active', 'yearly', '2026-10-01T00:00:00Z', '2027-10-01T00:00:00Z', false, 1)`,
      [id, `sub_test_${id.slice(0, 8)}`],
    );
  }
  return { token, id };
}

const appMessages = [
  { role: "system", content: "Popraw interpunkcje." },
  { role: "user", content: "tajny tekst dyktowania" },
];

/** The body the app's `OpenRouterClient.chatRequest` sends, plus whatever `extra` adds. */
function appChatBody(extra: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    model: "user/expensive-model",
    messages: appMessages,
    temperature: 0,
    max_tokens: 400,
    reasoning: { enabled: false },
    provider: { sort: "latency" },
    ...extra,
  };
}

function chat(token: string | undefined, body: unknown, headers: Record<string, string> = {}) {
  return app.request("/v1/chat/completions", {
    method: "POST",
    headers: { "Content-Type": "application/json", ...(token ? { Authorization: `Bearer ${token}` } : {}), ...headers },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
}

function vendorChat(totalTokens?: number): Response {
  return Response.json({
    id: "gen-1",
    model: "server/picked-model",
    choices: [{ message: { role: "assistant", content: "Poprawiony tekst." }, finish_reason: "stop" }],
    ...(totalTokens === undefined ? {} : { usage: { prompt_tokens: 100, completion_tokens: totalTokens - 100, total_tokens: totalTokens } }),
  });
}

const boundary = "Boundary-TEST-1234";

/** A multipart body like the app's `ElevenLabsSTT.makeUpload`, with `audio` as the file. */
function multipart(audio: Uint8Array): Uint8Array {
  const head = new TextEncoder().encode(
    `--${boundary}\r\nContent-Disposition: form-data; name="model_id"\r\n\r\nscribe_v1\r\n` +
      `--${boundary}\r\nContent-Disposition: form-data; name="file"; filename="audio.wav"\r\nContent-Type: audio/wav\r\n\r\n`,
  );
  const tail = new TextEncoder().encode(`\r\n--${boundary}--\r\n`);
  const out = new Uint8Array(head.length + audio.length + tail.length);
  out.set(head, 0);
  out.set(audio, head.length);
  out.set(tail, head.length + audio.length);
  return out;
}

function stt(token: string | undefined, body: Uint8Array | ReadableStream<Uint8Array>, headers: Record<string, string> = {}) {
  return app.request("/v1/speech-to-text", {
    method: "POST",
    headers: {
      "Content-Type": `multipart/form-data; boundary=${boundary}`,
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
      ...headers,
    },
    body,
    ...(body instanceof ReadableStream ? { duplex: "half" } : {}),
  } as RequestInit);
}

const vendorStt = () => Response.json({ language_code: "pol", text: "Dzień dobry.", words: [{ text: "Dzień", start: 0, end: 0.4, type: "word" }] });

function logsText(): string {
  return JSON.stringify(deps.log.lines);
}

describe("POST /v1/chat/completions", () => {
  it("needs a session and a Pro plan, and never calls the vendor otherwise", async () => {
    expect((await chat(undefined, appChatBody())).status).toBe(401);

    const free = await account("free@example.pl", "free");
    const res = await chat(free.token, appChatBody());
    expect(res.status).toBe(403);
    expect(await res.json()).toEqual({ error: "pro_required" });
    expect(deps.upstream.calls).toHaveLength(0);
  });

  it("swaps in the server's model and key and forwards only the fields the app uses", async () => {
    const { token } = await account();
    deps.upstream.respond = () => vendorChat(1_234);

    const res = await chat(token, appChatBody({ models: ["openai/o1-pro"], plugins: [{ id: "web" }], provider: { sort: "latency", only: ["x"] } }), {
      "X-Title": "Not Captylo",
    });
    expect(res.status).toBe(200);

    const call = deps.upstream.calls[0]!;
    expect(call.url).toBe("https://ai.upstream.test/api/v1/chat/completions");
    expect(call.method).toBe("POST");
    expect(call.headers.authorization).toBe(`Bearer ${AI_KEY}`);
    expect(call.headers["http-referer"]).toBe("https://captylo.com");
    expect(call.headers["x-title"]).toBe("Captylo");
    expect(call.headers["content-type"]).toBe("application/json");
    expect(JSON.parse(deps.upstream.lastText())).toEqual({
      model: "server/picked-model",
      messages: appMessages,
      temperature: 0,
      max_tokens: 400,
      reasoning: { enabled: false },
      provider: { sort: "latency" },
    });
    expect(deps.upstream.lastText()).not.toContain(token);
  });

  it("passes the vendor's answer through and counts its total_tokens", async () => {
    const { token, id } = await account();
    deps.upstream.respond = () => vendorChat(1_234);

    const res = await chat(token, appChatBody());
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toContain("application/json");
    const body = (await res.json()) as { choices: { message: { content: string } }[] };
    expect(body.choices[0]?.message.content).toBe("Poprawiony tekst.");
    expect(await usageFor(deps.db, id, deps.now())).toEqual({ audioSeconds: 0, aiTokens: 1_234 });

    const me = (await (await app.request("/v1/me", { headers: { Authorization: `Bearer ${token}` } })).json()) as { usage: { aiTokens: number } };
    expect(me.usage.aiTokens).toBe(1_234);
  });

  it("estimates the tokens from the bytes when the vendor sends no usage", async () => {
    const { token, id } = await account();
    deps.upstream.respond = () => vendorChat();

    expect((await chat(token, appChatBody())).status).toBe(200);
    const sent = deps.upstream.calls[0]!.body.length;
    const answer = new TextEncoder().encode(await vendorChat().text()).length;
    expect((await usageFor(deps.db, id, deps.now())).aiTokens).toBe(Math.ceil((sent + answer) / 4));
  });

  it("answers 402 quota_exceeded with the reset date once the month's tokens are used up", async () => {
    await setUp({ PRO_AI_TOKENS_PER_MONTH: "1000" });
    const { token, id } = await account();
    await addUsage(deps.db, id, deps.now(), { aiTokens: 1_000 });

    const res = await chat(token, appChatBody());
    expect(res.status).toBe(402);
    expect(await res.json()).toEqual({ error: "quota_exceeded", resetsAt: "2026-11-01T00:00:00.000Z" });
    expect(deps.upstream.calls).toHaveLength(0);
  });

  it("refuses a body over 2 MB and one without messages", async () => {
    const { token } = await account();
    const big = await chat(token, appChatBody({ messages: [{ role: "user", content: "a".repeat(2 * 1024 * 1024) }] }));
    expect(big.status).toBe(413);
    expect((await chat(token, { model: "x" })).status).toBe(400);
    expect((await chat(token, appChatBody({ messages: [] }))).status).toBe(400);
    expect((await chat(token, "not json")).status).toBe(400);
    expect(deps.upstream.calls).toHaveLength(0);
  });

  it.each([
    [429, 429, "upstream_busy"],
    [500, 502, "upstream_failed"],
    [503, 502, "upstream_failed"],
    [401, 502, "upstream_failed"],
    [402, 502, "upstream_failed"],
    [400, 400, "upstream_rejected"],
  ])("maps a vendor %i to %i %s without the vendor's text and counts nothing", async (vendor, status, error) => {
    const { token, id } = await account();
    deps.upstream.respond = () => Response.json({ error: { message: "vendor secret detail", code: vendor } }, { status: vendor });

    const res = await chat(token, appChatBody());
    expect(res.status).toBe(status);
    const text = await res.text();
    expect(JSON.parse(text)).toEqual({ error });
    expect(text).not.toContain("vendor secret detail");
    expect(await usageFor(deps.db, id, deps.now())).toEqual({ audioSeconds: 0, aiTokens: 0 });
  });

  it("answers 502 when the vendor cannot be reached", async () => {
    const { token } = await account();
    deps.upstream.respond = () => {
      throw new TypeError("fetch failed");
    };
    const res = await chat(token, appChatBody());
    expect(res.status).toBe(502);
    expect(await res.json()).toEqual({ error: "upstream_failed" });
  });

  it("answers 503 when the server has no AI key configured", async () => {
    await setUp({ OPENROUTER_API_KEY: "" });
    const { token } = await account();
    const res = await chat(token, appChatBody());
    expect(res.status).toBe(503);
    expect(await res.json()).toEqual({ error: "relay_unavailable" });
    expect(deps.upstream.calls).toHaveLength(0);
  });

  it("streams the vendor's events unchanged and counts the final usage chunk", async () => {
    const { token, id } = await account();
    const events =
      ": OPENROUTER PROCESSING\n\n" +
      'data: {"choices":[{"delta":{"content":"Popra"}}]}\n\n' +
      'data: {"choices":[{"delta":{"content":"wiony."}}]}\n\n' +
      'data: {"choices":[],"usage":{"prompt_tokens":50,"completion_tokens":7,"total_tokens":57}}\r\n\r\n' +
      "data: [DONE]\n\n";
    deps.upstream.respond = () => new Response(sse(events, 7), { headers: { "Content-Type": "text/event-stream" } });

    const res = await chat(token, appChatBody({ stream: true }));
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toBe("text/event-stream");
    expect(await res.text()).toBe(events);
    expect(JSON.parse(deps.upstream.lastText()).stream).toBe(true);
    expect((await usageFor(deps.db, id, deps.now())).aiTokens).toBe(57);
  });

  it("estimates a stream without a usage chunk from its bytes", async () => {
    const { token, id } = await account();
    const events = 'data: {"choices":[{"delta":{"content":"Tekst."}}]}\n\ndata: [DONE]\n\n';
    deps.upstream.respond = () => new Response(sse(events, 5), { headers: { "Content-Type": "text/event-stream" } });

    const res = await chat(token, appChatBody({ stream: true }));
    expect(await res.text()).toBe(events);
    const sent = deps.upstream.calls[0]!.body.length;
    expect((await usageFor(deps.db, id, deps.now())).aiTokens).toBe(Math.ceil((sent + events.length) / 4));
  });

  it("logs one relay line with counts and a user pseudonym, never the text, the token or a key", async () => {
    const { token, id } = await account();
    deps.upstream.respond = () => vendorChat(321);
    await chat(token, appChatBody());

    const relayLine = deps.log.lines.find((line) => line.fields.route === "chat");
    expect(relayLine?.fields).toMatchObject({ route: "chat", status: 200, tokens: 321 });
    expect(relayLine?.fields.user).toMatch(/^[0-9a-f]{16}$/);
    const logs = logsText();
    for (const secret of ["tajny tekst", "Poprawiony tekst", token, AI_KEY, id, "anna@example.pl"]) expect(logs).not.toContain(secret);
  });
});

describe("POST /v1/speech-to-text", () => {
  it("needs a session and a Pro plan", async () => {
    expect((await stt(undefined, multipart(new Uint8Array(10)), { "X-Captylo-Audio-Seconds": "5" })).status).toBe(401);
    const free = await account("free@example.pl", "free");
    const res = await stt(free.token, multipart(new Uint8Array(10)), { "X-Captylo-Audio-Seconds": "5" });
    expect(res.status).toBe(403);
    expect(await res.json()).toEqual({ error: "pro_required" });
    expect(deps.upstream.calls).toHaveLength(0);
  });

  it.each([
    ["missing", undefined],
    ["five hours", "18000"],
    ["zero", "0"],
    ["not a number", "abc"],
    ["fractional", "1.5"],
  ])("refuses the audio seconds header when %s", async (_label, value) => {
    const { token } = await account();
    const res = await stt(token, multipart(new Uint8Array(10)), value === undefined ? {} : { "X-Captylo-Audio-Seconds": value });
    expect(res.status).toBe(400);
    expect(deps.upstream.calls).toHaveLength(0);
  });

  it("accepts exactly four hours", async () => {
    const { token, id } = await account();
    deps.upstream.respond = vendorStt;
    expect((await stt(token, multipart(new Uint8Array(10)), { "X-Captylo-Audio-Seconds": "14400" })).status).toBe(200);
    expect((await usageFor(deps.db, id, deps.now())).audioSeconds).toBe(14_400);
  });

  it("refuses a body that is not multipart", async () => {
    const { token } = await account();
    const res = await stt(token, new Uint8Array(10), { "X-Captylo-Audio-Seconds": "5", "Content-Type": "audio/wav" });
    expect(res.status).toBe(400);
    expect(deps.upstream.calls).toHaveLength(0);
  });

  it("answers 402 before calling the vendor when the request would pass the monthly cap", async () => {
    await setUp({ PRO_AUDIO_HOURS_PER_MONTH: "1" });
    const { token, id } = await account();
    await addUsage(deps.db, id, deps.now(), { audioSeconds: 3_500 });

    const res = await stt(token, multipart(new Uint8Array(10)), { "X-Captylo-Audio-Seconds": "120" });
    expect(res.status).toBe(402);
    expect(await res.json()).toEqual({ error: "quota_exceeded", resetsAt: "2026-11-01T00:00:00.000Z" });
    expect(deps.upstream.calls).toHaveLength(0);

    deps.upstream.respond = vendorStt;
    expect((await stt(token, multipart(new Uint8Array(10)), { "X-Captylo-Audio-Seconds": "100" })).status).toBe(200);
  });

  it("streams the multipart body to the vendor unchanged with the server's key and counts the seconds", async () => {
    const { token, id } = await account();
    deps.upstream.respond = vendorStt;
    const body = multipart(new Uint8Array(randomBytes(1024 * 1024)));

    const res = await stt(token, body, { "X-Captylo-Audio-Seconds": "75", "xi-api-key": "users-own-key" });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual(await vendorStt().json());

    const call = deps.upstream.calls[0]!;
    expect(call.url).toBe("https://stt.upstream.test/v1/speech-to-text");
    expect(call.method).toBe("POST");
    expect(call.duplex).toBe("half");
    expect(call.headers["xi-api-key"]).toBe(STT_KEY);
    expect(call.headers["content-type"]).toBe(`multipart/form-data; boundary=${boundary}`);
    expect(call.headers.accept).toBe("application/json");
    expect(call.headers.authorization).toBeUndefined();
    expect(call.headers["x-captylo-audio-seconds"]).toBeUndefined();
    expect(Buffer.from(call.body).equals(Buffer.from(body))).toBe(true);
    expect(await usageFor(deps.db, id, deps.now())).toEqual({ audioSeconds: 75, aiTokens: 0 });
  });

  it("counts the audio the vendor transcribed when the header declares less", async () => {
    const { token, id } = await account();
    deps.upstream.respond = () =>
      Response.json({ language_code: "pol", text: "Dzień dobry.", words: [{ text: "Dzień", start: 0, end: 0.4, type: "word" }, { text: "dobry.", start: 3599.2, end: 3600, type: "word" }] });
    expect((await stt(token, multipart(new Uint8Array(10)), { "X-Captylo-Audio-Seconds": "1" })).status).toBe(200);
    expect((await usageFor(deps.db, id, deps.now())).audioSeconds).toBe(3600);
    const line = deps.log.lines.find((l) => l.fields.route === "stt" && l.fields.status === 200);
    expect(line?.fields).toMatchObject({ seconds: 3600, declaredSeconds: 1, measuredSeconds: 3600 });
  });

  it("counts the longest channel of a multichannel answer", async () => {
    const { token, id } = await account();
    deps.upstream.respond = () =>
      Response.json({
        transcripts: [
          { channel_index: 0, text: "a", words: [{ text: "a", start: 0, end: 120.2, type: "word" }] },
          { channel_index: 1, text: "b", words: [{ text: "b", start: 0, end: 1800.5, type: "word" }] },
        ],
      });
    expect((await stt(token, multipart(new Uint8Array(10)), { "X-Captylo-Audio-Seconds": "2" })).status).toBe(200);
    expect((await usageFor(deps.db, id, deps.now())).audioSeconds).toBe(1801);
  });

  it("estimates the audio from the transcript's length when the answer has no word times", async () => {
    const { token, id } = await account();
    // 2,500 characters of speech take at least 100 s even read very fast (25 characters a second).
    deps.upstream.respond = () => Response.json({ language_code: "pol", text: "x".repeat(2_500) });
    expect((await stt(token, multipart(new Uint8Array(10)), { "X-Captylo-Audio-Seconds": "3" })).status).toBe(200);
    expect((await usageFor(deps.db, id, deps.now())).audioSeconds).toBe(100);
  });

  it("keeps the declared seconds when the transcript is shorter", async () => {
    const { token, id } = await account();
    deps.upstream.respond = vendorStt;
    expect((await stt(token, multipart(new Uint8Array(10)), { "X-Captylo-Audio-Seconds": "75" })).status).toBe(200);
    expect((await usageFor(deps.db, id, deps.now())).audioSeconds).toBe(75);
  });

  it("allows three uploads of one account at a time", async () => {
    const { token } = await account();
    const release: Array<() => void> = [];
    deps.upstream.respond = () => new Promise<Response>((resolve) => release.push(() => resolve(vendorStt())));
    const running = [1, 2, 3].map(() => stt(token, multipart(new Uint8Array(10)), { "X-Captylo-Audio-Seconds": "5" }));
    while (release.length < 3) await new Promise((r) => setTimeout(r, 5));

    const fourth = await stt(token, multipart(new Uint8Array(10)), { "X-Captylo-Audio-Seconds": "5" });
    expect(fourth.status).toBe(429);
    expect(await fourth.json()).toEqual({ error: "too_many_requests" });
    expect(deps.upstream.calls).toHaveLength(3);

    for (const done of release) done();
    expect((await Promise.all(running)).map((r) => r.status)).toEqual([200, 200, 200]);
    deps.upstream.respond = vendorStt;
    expect((await stt(token, multipart(new Uint8Array(10)), { "X-Captylo-Audio-Seconds": "5" })).status).toBe(200);
  });

  it("streams a chunked upload (no Content-Length) unchanged", async () => {
    const { token } = await account();
    deps.upstream.respond = vendorStt;
    const body = multipart(new Uint8Array(randomBytes(256 * 1024)));
    const res = await stt(token, chunks(body, 64 * 1024), { "X-Captylo-Audio-Seconds": "10" });
    expect(res.status).toBe(200);
    expect(Buffer.from(deps.upstream.calls[0]!.body).equals(Buffer.from(body))).toBe(true);
  });

  it("refuses a declared size over the limit before calling the vendor", async () => {
    const { token } = await account();
    const res = await stt(token, multipart(new Uint8Array(10)), { "X-Captylo-Audio-Seconds": "5", "Content-Length": "300000000" });
    expect(res.status).toBe(413);
    expect(deps.upstream.calls).toHaveLength(0);
  });

  it.each([
    [422, 422, "bad_audio"],
    [429, 429, "upstream_busy"],
    [500, 502, "upstream_failed"],
    [401, 502, "upstream_failed"],
  ])("maps a vendor %i to %i %s and counts nothing", async (vendor, status, error) => {
    const { token, id } = await account();
    deps.upstream.respond = () => Response.json({ detail: { message: "vendor secret detail" } }, { status: vendor });

    const res = await stt(token, multipart(new Uint8Array(10)), { "X-Captylo-Audio-Seconds": "30" });
    expect(res.status).toBe(status);
    const text = await res.text();
    expect(JSON.parse(text)).toEqual({ error });
    expect(text).not.toContain("vendor secret detail");
    expect((await usageFor(deps.db, id, deps.now())).audioSeconds).toBe(0);
  });

  it("answers 503 when the server has no speech-to-text key configured", async () => {
    await setUp({ STT_API_KEY: "" });
    const { token } = await account();
    const res = await stt(token, multipart(new Uint8Array(10)), { "X-Captylo-Audio-Seconds": "5" });
    expect(res.status).toBe(503);
    expect(await res.json()).toEqual({ error: "relay_unavailable" });
  });

  it("logs the seconds and nothing of the audio or the transcript", async () => {
    const { token } = await account();
    deps.upstream.respond = vendorStt;
    await stt(token, multipart(new TextEncoder().encode("AUDIO-MARKER")), { "X-Captylo-Audio-Seconds": "42" });

    const relayLine = deps.log.lines.find((line) => line.fields.route === "stt");
    expect(relayLine?.fields).toMatchObject({ route: "stt", status: 200, seconds: 42 });
    const logs = logsText();
    for (const secret of ["AUDIO-MARKER", "Dzień dobry", token, STT_KEY, "anna@example.pl"]) expect(logs).not.toContain(secret);
  });
});

describe("limitStream", () => {
  it("passes a stream within the limit through and errors past it", async () => {
    const ok = limitStream(chunks(new Uint8Array(100), 30), 100);
    expect((await new Response(ok.stream).arrayBuffer()).byteLength).toBe(100);
    expect(ok.exceeded()).toBe(false);

    const over = limitStream(chunks(new Uint8Array(101), 30), 100);
    await expect(new Response(over.stream).arrayBuffer()).rejects.toThrow();
    expect(over.exceeded()).toBe(true);
  });
});

describe("tokensFromSse", () => {
  it("reads total_tokens from a data line and ignores everything else", () => {
    expect(tokensFromSse('data: {"usage":{"total_tokens":12}}')).toBe(12);
    expect(tokensFromSse('data: {"choices":[]}')).toBeUndefined();
    expect(tokensFromSse("data: [DONE]")).toBeUndefined();
    expect(tokensFromSse(": comment with usage")).toBeUndefined();
    expect(tokensFromSse('data: {"usage":')).toBeUndefined();
  });
});

/** `text` as a stream cut into `parts` pieces, so lines are split across chunks. */
function sse(text: string, parts: number): ReadableStream<Uint8Array> {
  return chunks(new TextEncoder().encode(text), Math.ceil(text.length / parts));
}

function chunks(bytes: Uint8Array, size: number): ReadableStream<Uint8Array> {
  let offset = 0;
  return new ReadableStream({
    pull(controller) {
      if (offset >= bytes.length) {
        controller.close();
        return;
      }
      controller.enqueue(bytes.slice(offset, offset + size));
      offset += size;
    },
  });
}
