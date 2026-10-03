import type { Db } from "../db.js";
import { LIVE_STATUSES, type SubscriptionRow } from "./entitlement.js";

/** A subscription as the webhook hands it over, already mapped from Stripe's object. */
export interface SubscriptionState {
  stripeSubscriptionId: string;
  customerId: string | undefined;
  status: string;
  plan: "yearly" | "monthly";
  currentPeriodStart: Date;
  currentPeriodEnd: Date;
  cancelAtPeriodEnd: boolean;
}

/** Stripe statuses a subscription never leaves. */
const TERMINAL_STATUSES = ["canceled", "incomplete_expired"];

/** The status a subscription starts in and never returns to once its first payment went through. */
const INITIAL_STATUS = "incomplete";

/** Statuses of a subscription that is paid up right now. */
export const PAID_STATUSES: readonly string[] = ["active", "trialing"];

/** Statuses of a subscription whose payment failed and that Stripe may still charge. */
export const UNPAID_STATUSES: readonly string[] = ["past_due", "unpaid"];

/** The stored subscription with the fields that decide whether another one may replace it. */
export interface StoredSubscription {
  stripe_subscription_id: string;
  status: string;
  cancel_at_period_end: boolean;
}

/** The user's subscription row, undefined when they never subscribed. */
export async function subscriptionFor(db: Db, userId: string): Promise<SubscriptionRow | undefined> {
  return db.one<SubscriptionRow>(
    "select status, plan, current_period_start, current_period_end, cancel_at_period_end from subscriptions where user_id = $1",
    [userId],
  );
}

/** Which subscription the user's row holds now, undefined when none. */
export async function storedSubscription(db: Db, userId: string): Promise<StoredSubscription | undefined> {
  return db.one<StoredSubscription>("select stripe_subscription_id, status, cancel_at_period_end from subscriptions where user_id = $1", [userId]);
}

/**
 * True when `stored` is paid up and set to renew: a second subscription of the same account is
 * then a duplicate (a site Checkout for an address that already has Pro, two parallel Checkouts)
 * and must not take its place.
 */
export function keepsOthersOut(stored: StoredSubscription): boolean {
  return PAID_STATUSES.includes(stored.status) && !stored.cancel_at_period_end;
}

/**
 * Stores `state` as the user's subscription when it is not older than what is stored.
 * Returns false (nothing written) when:
 * - the stored row comes from a newer Stripe event (`event_created`), so a late
 *   `customer.subscription.updated` never undoes a `deleted`;
 * - it is the same subscription and that one already ended (canceled is final in Stripe);
 * - it is the same subscription and the event says `incomplete` while the row has moved on:
 *   Stripe never returns a subscription to `incomplete`, so this is the late
 *   `customer.subscription.created` of a Checkout (events of the same second arrive in any order);
 * - it is a different, dead subscription while the stored one is live (an old subscription's
 *   late event never replaces the one the user pays for now);
 * - it is a different subscription while the stored one is paid up and renews (`keepsOthersOut`).
 */
export async function upsertSubscription(db: Db, userId: string, state: SubscriptionState, eventCreated: number, now: Date): Promise<boolean> {
  const rows = await db.query<{ user_id: string }>(
    `insert into subscriptions as s
       (user_id, stripe_subscription_id, status, plan, current_period_start, current_period_end, cancel_at_period_end, event_created, updated_at)
     values ($1, $2, $3, $4, $5, $6, $7, $8, $9)
     on conflict (user_id) do update set
       stripe_subscription_id = excluded.stripe_subscription_id,
       status = excluded.status,
       plan = excluded.plan,
       current_period_start = excluded.current_period_start,
       current_period_end = excluded.current_period_end,
       cancel_at_period_end = excluded.cancel_at_period_end,
       event_created = excluded.event_created,
       updated_at = excluded.updated_at
     where s.event_created <= excluded.event_created
       and not (s.stripe_subscription_id = excluded.stripe_subscription_id and s.status = any($10::text[]))
       and not (s.stripe_subscription_id = excluded.stripe_subscription_id and excluded.status = $12 and s.status <> $12)
       and (s.stripe_subscription_id = excluded.stripe_subscription_id
            or ((not (s.status = any($11::text[])) or excluded.status = any($11::text[]))
                and not (s.status = any($13::text[]) and not s.cancel_at_period_end)))
     returning user_id`,
    [
      userId,
      state.stripeSubscriptionId,
      state.status,
      state.plan,
      state.currentPeriodStart,
      state.currentPeriodEnd,
      state.cancelAtPeriodEnd,
      eventCreated,
      now,
      TERMINAL_STATUSES,
      LIVE_STATUSES,
      INITIAL_STATUS,
      PAID_STATUSES,
    ],
  );
  return rows.length > 0;
}
