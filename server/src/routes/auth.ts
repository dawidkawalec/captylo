import { Hono } from "hono";
import type { AppEnv, Deps } from "../app.js";
import { isEmail, issueCode, normalizeEmail, verifyCode } from "../lib/codes.js";
import { clientIp, readJsonObject, smallBody } from "../lib/http.js";
import { emailHash } from "../lib/ids.js";
import { loginCodeMessage, MailError } from "../lib/mail.js";
import { RateLimiter } from "../lib/rate-limit.js";
import { cleanDevice, issueSession, revokeSession } from "../lib/sessions.js";
import { findOrCreateUser } from "../lib/users.js";
import { requireSession } from "../middleware/session.js";
import { buildMe } from "./me.js";

const MINUTE_MS = 60_000;

/**
 * Sign in with an e-mail code:
 * - `POST /v1/auth/code` `{ email }` -> 204 for every address (no account enumeration);
 * - `POST /v1/auth/verify` `{ email, code, device }` -> `{ token, me }` or 400 `invalid_code`;
 * - `POST /v1/auth/logout` (bearer) -> 204.
 * The limiters live as long as this app instance (one process, see `RateLimiter`).
 */
export function authRoutes(deps: Deps): Hono<AppEnv> {
  const perAddress = new RateLimiter(5, 15 * MINUTE_MS);
  const perIp = new RateLimiter(30, 60 * MINUTE_MS);
  const limitBody = smallBody();
  const routes = new Hono<AppEnv>();

  routes.post("/auth/code", limitBody, async (c) => {
    const body = await readJsonObject(c);
    const email = typeof body?.email === "string" ? normalizeEmail(body.email) : "";
    if (!isEmail(email)) return c.json({ error: "bad_request" }, 400);

    const now = deps.now();
    const ip = clientIp(c);
    const addressOk = perAddress.allows(email, now);
    const ipOk = perIp.allows(ip, now);
    if (!addressOk || !ipOk) {
      deps.log.warn({ reqId: c.get("reqId"), limit: addressOk ? "ip" : "address", emailHash: emailHash(email) }, "login code rate limited");
      return c.body(null, 204);
    }
    perAddress.record(email, now);
    perIp.record(ip, now);

    const code = await issueCode(deps.db, email, now);
    const message = loginCodeMessage(code);
    try {
      await deps.mailer.send(email, message.subject, message.text, message.html);
    } catch (error) {
      const reason = error instanceof MailError ? error.message : error instanceof Error ? error.name : "unknown";
      deps.log.error({ reqId: c.get("reqId"), reason, emailHash: emailHash(email) }, "login code mail failed");
      return c.json({ error: "mail_failed" }, 502);
    }
    return c.body(null, 204);
  });

  routes.post("/auth/verify", limitBody, async (c) => {
    const body = await readJsonObject(c);
    const email = typeof body?.email === "string" ? normalizeEmail(body.email) : "";
    const code = body?.code;
    if (!isEmail(email) || typeof code !== "string") return c.json({ error: "bad_request" }, 400);
    // A malformed code is wrong without spending an attempt.
    if (!/^\d{6}$/.test(code)) return c.json({ error: "invalid_code" }, 400);
    const device = cleanDevice(body?.device);

    const now = deps.now();
    const signedIn = await deps.db.tx(async (t) => {
      if (!(await verifyCode(t, email, code, now))) return undefined;
      const user = await findOrCreateUser(t, email, now);
      const token = await issueSession(t, user.id, device, now);
      return { user, token };
    });
    if (!signedIn) return c.json({ error: "invalid_code" }, 400);
    return c.json({ token: signedIn.token, me: await buildMe(deps, signedIn.user) });
  });

  routes.post("/auth/logout", requireSession(deps), async (c) => {
    await revokeSession(deps.db, c.get("sessionId"), deps.now());
    return c.body(null, 204);
  });

  return routes;
}
