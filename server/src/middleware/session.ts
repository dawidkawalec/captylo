import type { MiddlewareHandler } from "hono";
import type { AppEnv, Deps } from "../app.js";
import { lookupSession } from "../lib/sessions.js";

/**
 * `Authorization: Bearer <token>` -> the signed-in user in `c.get("user")` and the session
 * id in `c.get("sessionId")`; 401 `{ "error": "unauthorized" }` for anything else.
 */
export function requireSession(deps: Pick<Deps, "db" | "config" | "now">): MiddlewareHandler<AppEnv> {
  return async (c, next) => {
    const header = c.req.header("Authorization") ?? "";
    const match = /^Bearer\s+(\S+)$/i.exec(header.trim());
    const session = match?.[1] ? await lookupSession(deps.db, match[1], deps.now(), deps.config.sessionDays) : undefined;
    if (!session) return c.json({ error: "unauthorized" }, 401);
    c.set("user", session.user);
    c.set("sessionId", session.id);
    await next();
  };
}
