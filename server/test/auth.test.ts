import { beforeEach, describe, expect, it } from "vitest";
import { buildApp } from "../src/app.js";
import type { Mailer } from "../src/lib/mail.js";
import { testDeps, type TestDeps } from "./helpers.js";

const minute = 60_000;
const hour = 60 * minute;
const day = 24 * hour;

let deps: TestDeps;
let app: ReturnType<typeof buildApp>;

beforeEach(async () => {
  deps = await testDeps();
  app = buildApp(deps);
});

function post(path: string, body: unknown, headers: Record<string, string> = {}) {
  return app.request(path, {
    method: "POST",
    headers: { "Content-Type": "application/json", ...headers },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
}

function requestCode(email: string, ip = "203.0.113.7") {
  return post("/v1/auth/code", { email }, { "X-Forwarded-For": `${ip}, 10.0.0.2` });
}

function lastCode(): string {
  const message = deps.mailer.sent.at(-1);
  const match = message?.text.match(/\b(\d{6})\b/);
  if (!match?.[1]) throw new Error("no code in the last message");
  return match[1];
}

function wrongCode(code: string): string {
  return String((Number(code) + 1) % 1_000_000).padStart(6, "0");
}

function verify(email: string, code: string, device = "MacBook Pro") {
  return post("/v1/auth/verify", { email, code, device });
}

async function signIn(email = "anna@example.pl", device = "MacBook Pro"): Promise<string> {
  expect((await requestCode(email)).status).toBe(204);
  const res = await verify(email, lastCode(), device);
  expect(res.status).toBe(200);
  const body = (await res.json()) as { token: string };
  return body.token;
}

function me(token?: string) {
  return app.request("/v1/me", { headers: token === undefined ? {} : { Authorization: `Bearer ${token}` } });
}

describe("POST /v1/auth/code", () => {
  it("answers 204 and mails one 6-digit code", async () => {
    const res = await requestCode("anna@example.pl");
    expect(res.status).toBe(204);
    expect(deps.mailer.sent).toHaveLength(1);
    const message = deps.mailer.sent[0]!;
    expect(message.to).toBe("anna@example.pl");
    expect(lastCode()).toMatch(/^\d{6}$/);
    expect(message.subject).toBe(`Twój kod do Captylo: ${lastCode()}`);
    expect(message.text).toContain("Wpisz go w aplikacji w ciągu 10 minut.");
    expect(message.text).toContain("Your Captylo code:");
    expect(message.html).toContain(lastCode());
  });

  it("answers 204 for an address with no account, exactly as for one with an account", async () => {
    await signIn("anna@example.pl");
    const known = await requestCode("anna@example.pl");
    const unknown = await requestCode("nobody@example.pl");
    expect(known.status).toBe(204);
    expect(unknown.status).toBe(204);
    expect(await known.text()).toBe(await unknown.text());
  });

  it("stores only a hash of the code", async () => {
    await requestCode("anna@example.pl");
    const rows = await deps.db.query<{ code_hash: string }>("select code_hash from login_codes");
    expect(rows).toHaveLength(1);
    expect(rows[0]!.code_hash).toMatch(/^[0-9a-f]{64}$/);
    expect(rows[0]!.code_hash).not.toContain(lastCode());
  });

  it("answers 400 when the address is missing or is not an e-mail, and for broken JSON", async () => {
    for (const body of [{}, { email: "" }, { email: "anna" }, { email: "anna@" }, { email: 42 }, "{not json"]) {
      const res = await post("/v1/auth/code", body);
      expect(res.status).toBe(400);
      expect(await res.json()).toEqual({ error: "bad_request" });
    }
    expect(deps.mailer.sent).toHaveLength(0);
  });

  it("limits one address to 5 codes per 15 minutes, still answering 204", async () => {
    for (let i = 0; i < 5; i++) {
      deps.clock.advance(minute);
      expect((await requestCode("anna@example.pl", `198.51.100.${i}`)).status).toBe(204);
    }
    expect(deps.mailer.sent).toHaveLength(5);
    const sixth = await requestCode("ANNA@example.pl", "198.51.100.99");
    expect(sixth.status).toBe(204);
    expect(deps.mailer.sent).toHaveLength(5);
    const warns = deps.log.lines.filter((l) => l.level === "warn");
    expect(warns).toHaveLength(1);
    expect(warns[0]!.fields).toMatchObject({ limit: "address" });
    expect(warns[0]!.fields.emailHash).toMatch(/^[0-9a-f]{16}$/);
    // 15 minutes after the first one a slot frees again.
    deps.clock.advance(11 * minute);
    await requestCode("anna@example.pl");
    expect(deps.mailer.sent).toHaveLength(6);
  });

  it("limits one IP to 30 codes per hour, whatever the addresses", async () => {
    for (let i = 0; i < 30; i++) await requestCode(`user${i}@example.pl`, "192.0.2.1");
    expect(deps.mailer.sent).toHaveLength(30);
    expect((await requestCode("late@example.pl", "192.0.2.1")).status).toBe(204);
    expect(deps.mailer.sent).toHaveLength(30);
    expect(deps.log.lines.filter((l) => l.level === "warn")[0]?.fields).toMatchObject({ limit: "ip" });
    // Another IP is not affected, and the refused address did not use up its own quota.
    await requestCode("late@example.pl", "192.0.2.2");
    expect(deps.mailer.sent).toHaveLength(31);
  });

  it("answers 502 when the mail cannot be sent, without details", async () => {
    const failing: Mailer = {
      send: async () => {
        throw new Error("provider said anna@example.pl bounced");
      },
    };
    app = buildApp({ ...deps, mailer: failing });
    const res = await requestCode("anna@example.pl");
    expect(res.status).toBe(502);
    expect(await res.json()).toEqual({ error: "mail_failed" });
  });

  it("refuses a body over 8 KB", async () => {
    const res = await post("/v1/auth/code", { email: "anna@example.pl", pad: "x".repeat(10_000) });
    expect(res.status).toBe(413);
    expect(await res.json()).toEqual({ error: "too_large" });
  });
});

describe("POST /v1/auth/verify", () => {
  it("returns a token and the Free account for the right code", async () => {
    await requestCode("anna@example.pl");
    const res = await verify("anna@example.pl", lastCode());
    expect(res.status).toBe(200);
    const body = (await res.json()) as { token: string; me: unknown };
    expect(body.token).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(body.me).toEqual({
      email: "anna@example.pl",
      plan: "free",
      status: null,
      periodEnd: null,
      cancelAtPeriodEnd: false,
      usage: { month: "2026-10", audioSeconds: 0, audioSecondsLimit: 72000, aiTokens: 0, aiTokensLimit: 3000000 },
    });
  });

  it("stores the device name and only a hash of the token", async () => {
    const token = await signIn("anna@example.pl", "  MacBook Pro Anny  ");
    const rows = await deps.db.query<{ token_hash: string; device: string }>("select token_hash, device from sessions");
    expect(rows).toHaveLength(1);
    expect(rows[0]!.device).toBe("MacBook Pro Anny");
    expect(rows[0]!.token_hash).toMatch(/^[0-9a-f]{64}$/);
    expect(rows[0]!.token_hash).not.toBe(token);
  });

  it("answers invalid_code for a wrong code and for an address that never asked for one", async () => {
    await requestCode("anna@example.pl");
    const wrong = await verify("anna@example.pl", wrongCode(lastCode()));
    expect(wrong.status).toBe(400);
    expect(await wrong.json()).toEqual({ error: "invalid_code" });
    const unknown = await verify("nobody@example.pl", "123456");
    expect(unknown.status).toBe(400);
    expect(await unknown.json()).toEqual({ error: "invalid_code" });
  });

  it("accepts the right code after four wrong ones", async () => {
    await requestCode("anna@example.pl");
    const code = lastCode();
    for (let i = 0; i < 4; i++) expect((await verify("anna@example.pl", wrongCode(code))).status).toBe(400);
    expect((await verify("anna@example.pl", code)).status).toBe(200);
  });

  it("invalidates the code after the fifth wrong attempt", async () => {
    await requestCode("anna@example.pl");
    const code = lastCode();
    for (let i = 0; i < 5; i++) expect((await verify("anna@example.pl", wrongCode(code))).status).toBe(400);
    const res = await verify("anna@example.pl", code);
    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ error: "invalid_code" });
  });

  it("refuses a code after 10 minutes", async () => {
    await requestCode("anna@example.pl");
    deps.clock.advance(11 * minute);
    expect((await verify("anna@example.pl", lastCode())).status).toBe(400);
  });

  it("accepts a code just before it expires", async () => {
    await requestCode("anna@example.pl");
    deps.clock.advance(9 * minute + 59_000);
    expect((await verify("anna@example.pl", lastCode())).status).toBe(200);
  });

  it("uses a code once", async () => {
    await requestCode("anna@example.pl");
    const code = lastCode();
    expect((await verify("anna@example.pl", code)).status).toBe(200);
    expect((await verify("anna@example.pl", code)).status).toBe(400);
  });

  it("consumes the first code when a second one is requested", async () => {
    await requestCode("anna@example.pl");
    const first = lastCode();
    await requestCode("anna@example.pl");
    const second = lastCode();
    if (first === second) return; // one in a million: nothing to tell apart
    expect((await verify("anna@example.pl", first)).status).toBe(400);
    expect((await verify("anna@example.pl", second)).status).toBe(200);
  });

  it("treats the address case-insensitively: one user for A@B.PL and a@b.pl", async () => {
    await requestCode("Anna@Example.PL");
    const first = await verify("anna@example.pl", lastCode());
    expect(first.status).toBe(200);
    expect(((await first.json()) as { me: { email: string } }).me.email).toBe("anna@example.pl");
    await requestCode("anna@example.pl");
    expect((await verify("ANNA@EXAMPLE.PL", lastCode())).status).toBe(200);
    const users = await deps.db.query("select id from users");
    expect(users).toHaveLength(1);
    expect(await deps.db.query("select id from sessions")).toHaveLength(2);
  });

  it("answers 400 for a missing field or a code that is not 6 digits", async () => {
    await requestCode("anna@example.pl");
    const missing = await post("/v1/auth/verify", { email: "anna@example.pl" });
    expect(missing.status).toBe(400);
    expect(await missing.json()).toEqual({ error: "bad_request" });
    const short = await verify("anna@example.pl", "12345");
    expect(short.status).toBe(400);
    expect(await short.json()).toEqual({ error: "invalid_code" });
    // A malformed code does not use up an attempt.
    expect((await verify("anna@example.pl", lastCode())).status).toBe(200);
  });
});

describe("sessions and GET /v1/me", () => {
  it("answers 401 without a token, with a malformed one and with an unknown one", async () => {
    for (const token of [undefined, "", "nope", "A".repeat(43)]) {
      const res = await me(token);
      expect(res.status).toBe(401);
      expect(await res.json()).toEqual({ error: "unauthorized" });
    }
    const basic = await app.request("/v1/me", { headers: { Authorization: "Basic YTpi" } });
    expect(basic.status).toBe(401);
  });

  it("answers the account for a valid token", async () => {
    const token = await signIn();
    const res = await me(token);
    expect(res.status).toBe(200);
    expect(await res.json()).toMatchObject({ email: "anna@example.pl", plan: "free", usage: { month: "2026-10" } });
  });

  it("logs out: the token stops working, other sessions keep working", async () => {
    const laptop = await signIn("anna@example.pl", "Laptop");
    const desktop = await signIn("anna@example.pl", "Desktop");
    const res = await app.request("/v1/auth/logout", { method: "POST", headers: { Authorization: `Bearer ${laptop}` } });
    expect(res.status).toBe(204);
    expect((await me(laptop)).status).toBe(401);
    expect((await me(desktop)).status).toBe(200);
  });

  it("requires a session to log out", async () => {
    const res = await app.request("/v1/auth/logout", { method: "POST" });
    expect(res.status).toBe(401);
  });

  it("bumps last_seen_at at most once an hour", async () => {
    const token = await signIn();
    const lastSeen = async () =>
      new Date(((await deps.db.one<{ last_seen_at: Date }>("select last_seen_at from sessions"))!).last_seen_at).toISOString();
    const signedInAt = await lastSeen();
    deps.clock.advance(30 * minute);
    await me(token);
    expect(await lastSeen()).toBe(signedInAt);
    deps.clock.advance(31 * minute);
    await me(token);
    expect(await lastSeen()).toBe(deps.clock.now().toISOString());
  });

  it("expires a session unused for SESSION_DAYS and keeps one in use", async () => {
    const token = await signIn();
    deps.clock.advance(179 * day);
    expect((await me(token)).status).toBe(200);
    deps.clock.advance(179 * day);
    expect((await me(token)).status).toBe(200);
    deps.clock.advance(181 * day);
    expect((await me(token)).status).toBe(401);
  });

  it("puts the month of the server clock in the usage", async () => {
    deps.clock.set("2026-12-31T23:30:00Z");
    const token = await signIn();
    expect(await (await me(token)).json()).toMatchObject({ usage: { month: "2026-12" } });
  });

  it("follows the caps from the configuration", async () => {
    deps = await testDeps({ PRO_AUDIO_HOURS_PER_MONTH: "1.5", PRO_AI_TOKENS_PER_MONTH: "1000" });
    app = buildApp(deps);
    const token = await signIn();
    expect(await (await me(token)).json()).toMatchObject({ usage: { audioSecondsLimit: 5400, aiTokensLimit: 1000 } });
  });
});

describe("privacy of the logs", () => {
  it("never logs the address, the code or the token", async () => {
    await requestCode("anna@example.pl");
    const code = lastCode();
    await verify("anna@example.pl", wrongCode(code));
    const res = await verify("anna@example.pl", code);
    const { token } = (await res.json()) as { token: string };
    await me(token);
    await app.request("/v1/auth/logout", { method: "POST", headers: { Authorization: `Bearer ${token}` } });
    for (let i = 0; i < 6; i++) await requestCode("anna@example.pl");
    const logged = JSON.stringify(deps.log.lines);
    expect(logged).not.toContain("anna@example.pl");
    expect(logged).not.toContain(code);
    expect(logged).not.toContain(token);
  });
});
