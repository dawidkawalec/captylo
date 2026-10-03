import { Hono } from "hono";
import { HTTPException } from "hono/http-exception";
import type { ContentfulStatusCode } from "hono/utils/http-status";
import type { Config } from "./config.js";
import type { Db } from "./db.js";
import { requestId } from "./lib/ids.js";
import type { Logger } from "./lib/log.js";
import type { Mailer } from "./lib/mail.js";
import type { SessionUser } from "./lib/sessions.js";
import type { StripeLike } from "./lib/stripe.js";
import { authRoutes } from "./routes/auth.js";
import { billingRoutes } from "./routes/billing.js";
import { healthRoutes } from "./routes/health.js";
import { meRoutes } from "./routes/me.js";
import { relayRoutes } from "./routes/relay.js";
import { stripeRoutes } from "./routes/stripe.js";

/** Everything a route needs, injected so tests pass fakes. */
export interface Deps {
  config: Config;
  db: Db;
  mailer: Mailer;
  /** The Stripe calls the billing routes and the webhook make. */
  stripe: StripeLike;
  /** The relay's calls to the AI and speech-to-text vendors (`fetch` in production). */
  fetchUpstream: typeof fetch;
  now: () => Date;
  log: Logger;
}

/** `user` and `sessionId` are set by `requireSession` on the routes that use it. */
export type AppEnv = { Variables: { reqId: string; user: SessionUser; sessionId: string } };

const genericErrors: Partial<Record<number, string>> = {
  400: "bad_request",
  401: "unauthorized",
  403: "forbidden",
  404: "not_found",
  405: "method_not_allowed",
  413: "too_large",
  429: "rate_limited",
};

export function buildApp(deps: Deps): Hono<AppEnv> {
  const app = new Hono<AppEnv>();

  app.use("*", async (c, next) => {
    const reqId = requestId();
    c.set("reqId", reqId);
    const started = performance.now();
    await next();
    setHeader(c, "X-Request-Id", reqId);
    deps.log.info({
      reqId,
      method: c.req.method,
      path: c.req.path,
      status: c.res.status,
      ms: Math.round(performance.now() - started),
    });
  });

  app.route("/v1", healthRoutes());
  app.route("/v1", authRoutes(deps));
  app.route("/v1", meRoutes(deps));
  app.route("/v1", billingRoutes(deps));
  app.route("/v1", stripeRoutes(deps));
  app.route("/v1", relayRoutes(deps));

  app.notFound((c) => c.json({ error: "not_found" }, 404));

  app.onError((err, c) => {
    const reqId = c.get("reqId");
    if (err instanceof HTTPException && err.status < 500) {
      return c.json({ error: genericErrors[err.status] ?? "bad_request" }, err.status as ContentfulStatusCode);
    }
    // The message can carry user data (a pg duplicate-key error quotes the value), so only
    // the error's type, the driver's code and a few stack frames reach the log.
    deps.log.error({ reqId, error: err.name, code: errorCode(err), at: stackFrames(err) });
    return c.json({ error: "internal", requestId: reqId }, 500);
  });

  return app;
}

type HeaderContext = { res: Response };

/** Sets a header on the final response, copying it first when its headers are immutable (a passed-through fetch). */
function setHeader(c: HeaderContext, name: string, value: string): void {
  try {
    c.res.headers.set(name, value);
  } catch {
    c.res = new Response(c.res.body, c.res);
    c.res.headers.set(name, value);
  }
}

function errorCode(err: Error): string | undefined {
  const code = (err as { code?: unknown }).code;
  return typeof code === "string" ? code : undefined;
}

function stackFrames(err: Error): string | undefined {
  const frames = err.stack
    ?.split("\n")
    .filter((line) => line.trimStart().startsWith("at "))
    .slice(0, 3)
    .map((line) => line.trim());
  return frames && frames.length > 0 ? frames.join(" | ") : undefined;
}
