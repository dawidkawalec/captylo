import { Hono } from "hono";
import type { AppEnv, Deps } from "../app.js";
import { entitlement } from "../lib/entitlement.js";
import type { SessionUser } from "../lib/sessions.js";
import { subscriptionFor } from "../lib/subscriptions.js";
import { monthKey, usageFor } from "../lib/usage.js";
import { requireSession } from "../middleware/session.js";

/** The account as the app sees it: `GET /v1/me` and the `me` of `POST /v1/auth/verify`. */
export interface Me {
  email: string;
  plan: "free" | "pro";
  status: string | null;
  periodEnd: string | null;
  cancelAtPeriodEnd: boolean;
  usage: {
    /** "YYYY-MM", UTC */
    month: string;
    audioSeconds: number;
    audioSecondsLimit: number;
    aiTokens: number;
    aiTokensLimit: number;
  };
}

/**
 * Builds the account view: the plan from the stored subscription (`entitlement`), this month's
 * relay counters, the limits from the Pro caps in the config.
 */
export async function buildMe(deps: Pick<Deps, "config" | "now" | "db">, user: SessionUser): Promise<Me> {
  const now = deps.now();
  const plan = entitlement(await subscriptionFor(deps.db, user.id), now);
  const usage = await usageFor(deps.db, user.id, now);
  return {
    email: user.email,
    plan: plan.plan,
    status: plan.status,
    periodEnd: plan.periodEnd ? plan.periodEnd.toISOString() : null,
    cancelAtPeriodEnd: plan.cancelAtPeriodEnd,
    usage: {
      month: monthKey(now),
      audioSeconds: usage.audioSeconds,
      audioSecondsLimit: Math.floor(deps.config.proAudioHoursPerMonth * 3600),
      aiTokens: usage.aiTokens,
      aiTokensLimit: deps.config.proAiTokensPerMonth,
    },
  };
}

/** `GET /v1/me` (bearer). */
export function meRoutes(deps: Deps): Hono<AppEnv> {
  const routes = new Hono<AppEnv>();
  routes.get("/me", requireSession(deps), async (c) => c.json(await buildMe(deps, c.get("user"))));
  return routes;
}
