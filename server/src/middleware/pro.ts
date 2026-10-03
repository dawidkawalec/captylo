import type { MiddlewareHandler } from "hono";
import type { AppEnv, Deps } from "../app.js";
import { entitlement } from "../lib/entitlement.js";
import { subscriptionFor } from "../lib/subscriptions.js";

/**
 * Lets only Pro accounts through (after `requireSession`); anyone else gets 403
 * `{ "error": "pro_required" }`. The plan is read on every request, so a cancelled or
 * unpaid subscription stops the relay at once.
 */
export function requirePro(deps: Pick<Deps, "db" | "now">): MiddlewareHandler<AppEnv> {
  return async (c, next) => {
    const sub = await subscriptionFor(deps.db, c.get("user").id);
    if (entitlement(sub, deps.now()).plan !== "pro") return c.json({ error: "pro_required" }, 403);
    await next();
  };
}
