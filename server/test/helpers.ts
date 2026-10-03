import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { PGlite } from "@electric-sql/pglite";
import { citext } from "@electric-sql/pglite/contrib/citext";
import type Stripe from "stripe";
import type { Deps } from "../src/app.js";
import { loadConfig, type Config } from "../src/config.js";
import { migrate, type Db } from "../src/db.js";
import type { LogFields, Logger } from "../src/lib/log.js";
import { LogMailer } from "../src/lib/mail.js";
import type { StripeLike } from "../src/lib/stripe.js";

/** A `Db` over an in-process pglite instance, the same contract as `dbFromPool`. */
export function dbFromPglite(pg: PGlite): Db {
  return wrap(pg, false);
}

type PgliteLike = Pick<PGlite, "query" | "exec">;

function wrap(pg: PgliteLike & Partial<Pick<PGlite, "transaction">>, inTx: boolean): Db {
  const db: Db = {
    async query<T>(text: string, params?: unknown[]): Promise<T[]> {
      const result = await pg.query<T>(text, params);
      return result.rows;
    },
    async one<T>(text: string, params?: unknown[]): Promise<T | undefined> {
      const result = await pg.query<T>(text, params);
      return result.rows[0];
    },
    async exec(sql: string): Promise<void> {
      await pg.exec(sql);
    },
    async tx<T>(fn: (db: Db) => Promise<T>): Promise<T> {
      if (inTx || !pg.transaction) return fn(db);
      return pg.transaction((t) => fn(wrap(t, true)));
    },
  };
  return db;
}

/** A fresh database with every migration applied. */
export async function testDb(): Promise<{ db: Db; pg: PGlite }> {
  const pg = new PGlite({ extensions: { citext } });
  const db = dbFromPglite(pg);
  await migrate(db);
  return { db, pg };
}

/** An empty database (no migrations), for the migration tests themselves. */
export function emptyDb(): { db: Db; pg: PGlite } {
  const pg = new PGlite({ extensions: { citext } });
  return { db: dbFromPglite(pg), pg };
}

export interface LogLine {
  level: "info" | "warn" | "error";
  fields: LogFields;
  msg?: string;
}

/** Records log lines instead of printing them. */
export function memoryLogger(): Logger & { lines: LogLine[] } {
  const lines: LogLine[] = [];
  const record = (level: LogLine["level"]) => (fields: LogFields, msg?: string) => {
    lines.push(msg === undefined ? { level, fields } : { level, fields, msg });
  };
  return { lines, info: record("info"), warn: record("warn"), error: record("error") };
}

export function testConfig(overrides: Record<string, string> = {}): Config {
  return loadConfig({ NODE_ENV: "test", DATABASE_URL: "postgres://test@localhost/test", ...overrides });
}

/** A clock tests can move: `clock.now()` is what the app sees, `clock.advance(ms)` moves it. */
export function testClock(start = "2026-10-03T12:00:00Z"): { now: () => Date; advance: (ms: number) => void; set: (iso: string) => void } {
  let current = new Date(start).getTime();
  return {
    now: () => new Date(current),
    advance: (ms) => {
      current += ms;
    },
    set: (iso) => {
      current = new Date(iso).getTime();
    },
  };
}

export interface StripeCall {
  method: string;
  params: unknown;
}

/**
 * Stands in for Stripe: records every call and answers with canned objects. Customers are
 * `cus_fake_1`, `cus_fake_2`, ...; `subscriptions.retrieve` answers from `subscriptionsById`;
 * `constructEvent` accepts the signature `"test"` (and parses the body) and throws otherwise.
 * Set `failWith` to make the next calls that reach Stripe throw it.
 */
export class FakeStripe implements StripeLike {
  readonly calls: StripeCall[] = [];
  readonly subscriptionsById = new Map<string, Stripe.Subscription>();
  failWith: Error | undefined;
  private customerCount = 0;

  readonly customers = {
    create: async (params: Stripe.CustomerCreateParams) => {
      this.record("customers.create", params);
      this.customerCount += 1;
      return { id: `cus_fake_${this.customerCount}` };
    },
  };

  readonly checkout = {
    sessions: {
      create: async (params: Stripe.Checkout.SessionCreateParams) => {
        this.record("checkout.sessions.create", params);
        const n = this.callsOf("checkout.sessions.create").length;
        return { id: `cs_fake_${n}`, url: `https://checkout.stripe.com/c/pay/cs_fake_${n}` };
      },
    },
  };

  readonly billingPortal = {
    sessions: {
      create: async (params: Stripe.BillingPortal.SessionCreateParams) => {
        this.record("billingPortal.sessions.create", params);
        return { url: "https://billing.stripe.com/p/session/fake_1" };
      },
    },
  };

  readonly webhooks = {
    constructEvent: (payload: string, header: string, secret: string): Stripe.Event => {
      this.calls.push({ method: "webhooks.constructEvent", params: { header, secret } });
      if (header !== "test") throw Object.assign(new Error("No signatures found matching the expected signature"), { type: "StripeSignatureVerificationError" });
      return JSON.parse(payload) as Stripe.Event;
    },
  };

  readonly subscriptions = {
    retrieve: async (id: string): Promise<Stripe.Subscription> => {
      this.record("subscriptions.retrieve", { id });
      const sub = this.subscriptionsById.get(id);
      if (!sub) throw Object.assign(new Error(`No such subscription: '${id}'`), { type: "StripeInvalidRequestError", code: "resource_missing" });
      return structuredClone(sub);
    },
  };

  callsOf(method: string): StripeCall[] {
    return this.calls.filter((call) => call.method === method);
  }

  private record(method: string, params: unknown): void {
    this.calls.push({ method, params });
    if (this.failWith) throw this.failWith;
  }
}

/** One request the relay sent upstream, with its body read to the end. */
export interface UpstreamCall {
  url: string;
  method: string;
  headers: Record<string, string>;
  body: Uint8Array;
  duplex: string | undefined;
}

/**
 * Stands in for the vendors' HTTP APIs: records every request (reading its body, so a
 * streamed upload is consumed like the network would) and answers with `respond`, which
 * tests replace. The default answer is a 500, so a test that forgets to set one fails loudly.
 */
export class FakeUpstream {
  readonly calls: UpstreamCall[] = [];
  respond: (call: UpstreamCall) => Response | Promise<Response> = () => new Response("not set", { status: 500 });

  readonly fetch = (async (input: string | URL | Request, init?: RequestInit): Promise<Response> => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
    const headers: Record<string, string> = {};
    new Headers(init?.headers).forEach((value, name) => {
      headers[name] = value;
    });
    const body = init?.body === undefined || init.body === null ? new Uint8Array() : new Uint8Array(await new Response(init.body).arrayBuffer());
    const call: UpstreamCall = { url, method: init?.method ?? "GET", headers, body, duplex: (init as { duplex?: string } | undefined)?.duplex };
    this.calls.push(call);
    return this.respond(call);
  }) as typeof fetch;

  /** The body of the last call as text. */
  lastText(): string {
    return new TextDecoder().decode(this.calls.at(-1)?.body ?? new Uint8Array());
  }
}

export type TestDeps = Deps & {
  log: ReturnType<typeof memoryLogger>;
  mailer: LogMailer;
  stripe: FakeStripe;
  upstream: FakeUpstream;
  clock: ReturnType<typeof testClock>;
  pg: PGlite;
};

/** The price ids the fake Stripe setup uses (`STRIPE_PRICE_YEARLY`, `STRIPE_PRICE_MONTHLY`). */
export const testPrices = { yearly: "price_test_yearly", monthly: "price_test_monthly" } as const;

/** Every dependency of `buildApp` with fakes: pglite, a recording mailer, a fake Stripe, a fake upstream, a movable clock, a memory log. */
export async function testDeps(configOverrides: Record<string, string> = {}): Promise<TestDeps> {
  const { db, pg } = await testDb();
  const clock = testClock();
  const upstream = new FakeUpstream();
  return {
    config: testConfig({ STRIPE_PRICE_YEARLY: testPrices.yearly, STRIPE_PRICE_MONTHLY: testPrices.monthly, ...configOverrides }),
    db,
    pg,
    mailer: new LogMailer("test"),
    stripe: new FakeStripe(),
    upstream,
    fetchUpstream: upstream.fetch,
    clock,
    now: clock.now,
    log: memoryLogger(),
  };
}

/** A webhook payload from `test/fixtures/stripe/<name>.json`, a fresh copy each call. */
export function stripeFixture(name: string): Stripe.Event {
  const path = fileURLToPath(new URL(`./fixtures/stripe/${name}.json`, import.meta.url));
  return JSON.parse(readFileSync(path, "utf8")) as Stripe.Event;
}

/** Signs a user in through the real code flow and returns the bearer token. */
export async function signIn(app: { request: (path: string, init?: RequestInit) => Response | Promise<Response> }, mailer: LogMailer, email: string): Promise<string> {
  const post = (path: string, body: unknown) =>
    app.request(path, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });
  const sent = await post("/v1/auth/code", { email });
  if (sent.status !== 204) throw new Error(`auth/code answered ${sent.status}`);
  const code = mailer.sent.at(-1)?.text.match(/\b(\d{6})\b/)?.[1];
  if (!code) throw new Error("no code mailed");
  const res = await post("/v1/auth/verify", { email, code, device: "Test Mac" });
  if (res.status !== 200) throw new Error(`auth/verify answered ${res.status}`);
  return ((await res.json()) as { token: string }).token;
}
