/** A row of `subscriptions` as far as the plan depends on it. */
export interface SubscriptionRow {
  status: string;
  plan: "yearly" | "monthly";
  current_period_start: Date;
  current_period_end: Date;
  cancel_at_period_end: boolean;
}

export type Plan = "free" | "pro";

export interface Entitlement {
  plan: Plan;
  /** The Stripe status of the subscription, null when there is none. */
  status: string | null;
  periodEnd: Date | null;
  cancelAtPeriodEnd: boolean;
}

/** How long `past_due` stays Pro after the unpaid period started: the card retry window. */
export const PAST_DUE_GRACE_MS = 3 * 24 * 60 * 60_000;

/** Statuses that keep (or may keep) Pro; the webhook prefers such a subscription over a dead one. */
export const LIVE_STATUSES: readonly string[] = ["active", "trialing", "past_due"];

/**
 * The plan a subscription gives right now. `active` and `trialing` are Pro; `past_due` stays
 * Pro for 3 days from `current_period_start`; everything else (canceled, unpaid, incomplete,
 * paused, a status Stripe adds later) is Free.
 *
 * The grace counts from the period start, not the end: Stripe moves the period to the next one
 * when it creates the renewal invoice, before it charges the card, so a subscription that turns
 * `past_due` on a failed renewal already has its period end a month or a year ahead.
 */
export function entitlement(sub: SubscriptionRow | undefined, now: Date): Entitlement {
  if (!sub) return { plan: "free", status: null, periodEnd: null, cancelAtPeriodEnd: false };
  const periodStart = new Date(sub.current_period_start);
  const periodEnd = new Date(sub.current_period_end);
  let plan: Plan = "free";
  if (sub.status === "active" || sub.status === "trialing") {
    plan = "pro";
  } else if (sub.status === "past_due" && now.getTime() <= periodStart.getTime() + PAST_DUE_GRACE_MS) {
    plan = "pro";
  }
  return { plan, status: sub.status, periodEnd, cancelAtPeriodEnd: sub.cancel_at_period_end };
}
