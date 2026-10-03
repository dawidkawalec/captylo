import type Stripe from "stripe";
import type { Config } from "../config.js";
import type { Db } from "../db.js";
import { isEmail, normalizeEmail } from "./codes.js";
import type { SessionUser } from "./sessions.js";
import { stripeId, type StripeLike } from "./stripe.js";
import { LIVE_STATUSES } from "./entitlement.js";
import { keepsOthersOut, storedSubscription, UNPAID_STATUSES, upsertSubscription, type SubscriptionState } from "./subscriptions.js";
import { findOrCreateUser } from "./users.js";

/**
 * What a webhook event did, for the log line:
 * - `applied`: the subscription row changed;
 * - `stale`: an older or superseded event, nothing written;
 * - `ignored`: an event or object we do not act on (invoices, one-off payments, other types);
 * - `not_ours`: a subscription to a price that is not Captylo Pro;
 * - `unknown_customer`: a subscription of a customer no account is linked to (yet);
 * - `no_user`: a Checkout with neither a known reference nor an e-mail address;
 * - `duplicate_subscription`: a second live subscription of an account that already pays for a
 *   renewing one; the stored one and its customer stay, the new one needs a manual refund;
 * - `replaced_unpaid`: a new live subscription took the place of an unpaid (past_due, unpaid)
 *   one Stripe may still charge; the old one needs a manual cancel.
 */
export type EventOutcome = "applied" | "stale" | "ignored" | "not_ours" | "unknown_customer" | "no_user" | "duplicate_subscription" | "replaced_unpaid";

export type PriceIds = Pick<Config, "stripePriceYearly" | "stripePriceMonthly">;

/** What an event needs from Stripe, fetched before the transaction so no network call holds a database connection. */
export interface Prefetched {
  subscription?: Stripe.Subscription;
}

const SUBSCRIPTION_EVENTS = new Set(["customer.subscription.created", "customer.subscription.updated", "customer.subscription.deleted"]);

/** The plan of a subscription: `metadata.plan` (set by our Checkout), else by price id; undefined when it is not Captylo Pro. */
export function planOf(sub: Stripe.Subscription, prices: PriceIds): "yearly" | "monthly" | undefined {
  const fromMetadata = sub.metadata?.plan;
  if (fromMetadata === "yearly" || fromMetadata === "monthly") return fromMetadata;
  const priceId = sub.items?.data?.[0]?.price?.id;
  if (priceId && priceId === prices.stripePriceYearly) return "yearly";
  if (priceId && priceId === prices.stripePriceMonthly) return "monthly";
  return undefined;
}

/**
 * The current period, start and end. Since API 2025-03 it lives on the subscription item; older
 * payloads carry it on the subscription itself. Undefined unless both ends come from the same place.
 */
export function periodOf(sub: Stripe.Subscription): { start: Date; end: Date } | undefined {
  const legacy = sub as { current_period_start?: unknown; current_period_end?: unknown };
  for (const source of [sub.items?.data?.[0], legacy]) {
    const start = source?.current_period_start;
    const end = source?.current_period_end;
    if (typeof start === "number" && typeof end === "number") return { start: new Date(start * 1000), end: new Date(end * 1000) };
  }
  return undefined;
}

/** A Stripe subscription as we store it; undefined when it is not Captylo Pro or has no period. */
export function subscriptionState(sub: Stripe.Subscription, prices: PriceIds, deleted = false): SubscriptionState | undefined {
  const plan = planOf(sub, prices);
  const period = periodOf(sub);
  if (!plan || !period) return undefined;
  return {
    stripeSubscriptionId: sub.id,
    customerId: stripeId(sub.customer),
    status: deleted ? "canceled" : sub.status,
    plan,
    currentPeriodStart: period.start,
    currentPeriodEnd: period.end,
    cancelAtPeriodEnd: Boolean(sub.cancel_at_period_end),
  };
}

/** Fetches what `applyStripeEvent` needs from Stripe: the subscription of a completed subscription Checkout. */
export async function prefetchForEvent(stripe: StripeLike, event: Stripe.Event): Promise<Prefetched> {
  if (event.type !== "checkout.session.completed") return {};
  const session = event.data.object;
  if (session.mode !== "subscription" || !session.subscription) return {};
  if (typeof session.subscription !== "string") return { subscription: session.subscription };
  return { subscription: await stripe.subscriptions.retrieve(session.subscription) };
}

/** Applies one verified event inside the caller's transaction. */
export async function applyStripeEvent(
  db: Db,
  prices: PriceIds,
  event: Stripe.Event,
  prefetched: Prefetched,
  now: Date,
): Promise<EventOutcome> {
  if (event.type === "checkout.session.completed") {
    return applyCheckout(db, prices, event.data.object, prefetched.subscription, event.created, now);
  }
  if (SUBSCRIPTION_EVENTS.has(event.type)) {
    const sub = event.data.object as Stripe.Subscription;
    return applySubscription(db, prices, sub, event.type === "customer.subscription.deleted", event.created, now);
  }
  return "ignored";
}

async function applyCheckout(
  db: Db,
  prices: PriceIds,
  session: Stripe.Checkout.Session,
  subscription: Stripe.Subscription | undefined,
  eventCreated: number,
  now: Date,
): Promise<EventOutcome> {
  // The same Stripe account sells one-off payments (the coffee link): only subscriptions count.
  if (session.mode !== "subscription" || !subscription) return "ignored";
  const state = subscriptionState(subscription, prices);
  if (!state) return "not_ours";
  const customerId = stripeId(session.customer) ?? state.customerId;
  const user = await userForCheckout(db, session, customerId, now);
  if (!user) return "no_user";
  const outcome = await storeSubscription(db, user.id, state, eventCreated, now);
  // The Portal opens for the account's customer, so it follows the customer of the stored
  // subscription: a site Checkout always makes a new customer, even for an account that has one.
  // A duplicate keeps the account on the customer of the subscription it already pays for.
  if (customerId) await linkCustomer(db, user.id, customerId, isApplied(outcome));
  return outcome;
}

async function applySubscription(
  db: Db,
  prices: PriceIds,
  sub: Stripe.Subscription,
  deleted: boolean,
  eventCreated: number,
  now: Date,
): Promise<EventOutcome> {
  const state = subscriptionState(sub, prices, deleted);
  if (!state) return "not_ours";
  const userId = await userForSubscription(db, state);
  if (!userId) return "unknown_customer";
  return storeSubscription(db, userId, state, eventCreated, now);
}

function isApplied(outcome: EventOutcome): boolean {
  return outcome === "applied" || outcome === "replaced_unpaid";
}

/** Upserts the subscription and names what happened, so the cases that need a manual step log a warning. */
async function storeSubscription(db: Db, userId: string, state: SubscriptionState, eventCreated: number, now: Date): Promise<EventOutcome> {
  const stored = await storedSubscription(db, userId);
  const before = stored && stored.stripe_subscription_id !== state.stripeSubscriptionId && LIVE_STATUSES.includes(state.status) ? stored : undefined;
  if (!(await upsertSubscription(db, userId, state, eventCreated, now))) {
    return before && keepsOthersOut(before) ? "duplicate_subscription" : "stale";
  }
  return before && UNPAID_STATUSES.includes(before.status) ? "replaced_unpaid" : "applied";
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * The account a Checkout pays for: the signed-in user it was opened for (`client_reference_id`),
 * else the account linked to the customer, else the account with the e-mail Stripe collected
 * (created when missing: the site's "Wybierz Pro" path, the user signs in with it later).
 */
async function userForCheckout(db: Db, session: Stripe.Checkout.Session, customerId: string | undefined, now: Date): Promise<SessionUser | undefined> {
  const reference = session.client_reference_id;
  if (reference && UUID.test(reference)) {
    const user = await db.one<SessionUser>("select id, email from users where id = $1", [reference]);
    if (user) return user;
  }
  if (customerId) {
    const user = await db.one<SessionUser>("select id, email from users where stripe_customer_id = $1", [customerId]);
    if (user) return user;
  }
  const email = normalizeEmail(session.customer_details?.email ?? session.customer_email ?? "");
  if (!isEmail(email)) return undefined;
  return findOrCreateUser(db, email, now);
}

/** The account a subscription belongs to: by the subscription we already store, else by its customer. */
async function userForSubscription(db: Db, state: SubscriptionState): Promise<string | undefined> {
  const bySubscription = await db.one<{ user_id: string }>("select user_id from subscriptions where stripe_subscription_id = $1", [
    state.stripeSubscriptionId,
  ]);
  if (bySubscription) return bySubscription.user_id;
  if (!state.customerId) return undefined;
  const byCustomer = await db.one<{ id: string }>("select id from users where stripe_customer_id = $1", [state.customerId]);
  return byCustomer?.id;
}

/**
 * Links the customer to the user when no other account holds it: always when `replace` (the
 * Checkout's subscription was stored), else only when the user has no customer yet.
 */
async function linkCustomer(db: Db, userId: string, customerId: string, replace: boolean): Promise<void> {
  await db.query(
    `update users set stripe_customer_id = $2
      where id = $1 and ($3::boolean or stripe_customer_id is null)
        and not exists (select 1 from users where stripe_customer_id = $2)`,
    [userId, customerId, replace],
  );
}
