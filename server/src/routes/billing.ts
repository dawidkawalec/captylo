import { Hono, type Context } from "hono";
import type Stripe from "stripe";
import type { AppEnv, Deps } from "../app.js";
import type { Config } from "../config.js";
import { entitlement } from "../lib/entitlement.js";
import { clientIp, readJsonObject, smallBody } from "../lib/http.js";
import { RateLimiter } from "../lib/rate-limit.js";
import type { SessionUser } from "../lib/sessions.js";
import { stripeErrorFields, StripeNotConfiguredError } from "../lib/stripe.js";
import { subscriptionFor, UNPAID_STATUSES } from "../lib/subscriptions.js";
import { requireSession } from "../middleware/session.js";

export type BillingPlan = "yearly" | "monthly";

const HOUR_MS = 60 * 60_000;

export function isBillingPlan(value: unknown): value is BillingPlan {
  return value === "yearly" || value === "monthly";
}

/** The Stripe price of a plan; "" when it is not configured (development). */
export function priceFor(plan: BillingPlan, config: Pick<Config, "stripePriceYearly" | "stripePriceMonthly">): string {
  return plan === "yearly" ? config.stripePriceYearly : config.stripePriceMonthly;
}

/**
 * The Checkout Session for a plan. From the app it is tied to the signed-in user (`customer`,
 * `client_reference_id`) and saves the address Stripe Tax needs on that customer; from the site
 * there is no account yet, Stripe collects the e-mail and the webhook creates the account.
 */
export function checkoutParams(
  plan: BillingPlan,
  price: string,
  publicSiteUrl: string,
  buyer?: { userId: string; customerId: string },
): Stripe.Checkout.SessionCreateParams {
  return {
    mode: "subscription",
    ...(buyer ? { customer: buyer.customerId, client_reference_id: buyer.userId } : {}),
    line_items: [{ price, quantity: 1 }],
    allow_promotion_codes: true,
    automatic_tax: { enabled: true },
    // Stripe accepts customer_update only with an existing customer.
    ...(buyer ? { customer_update: { address: "auto", name: "auto" } } : {}),
    tax_id_collection: { enabled: true },
    billing_address_collection: "auto",
    locale: "auto",
    success_url: `${publicSiteUrl}/pro/dziekujemy/?from=${buyer ? "app" : "site"}`,
    cancel_url: `${publicSiteUrl}/#cennik`,
    subscription_data: { metadata: { plan } },
  };
}

/**
 * Billing:
 * - `POST /v1/billing/checkout` (bearer) `{ plan }` -> `{ url }` of a Checkout for this account;
 *   409 `already_pro` when the account is Pro already, 409 `payment_pending` while its
 *   subscription is past_due or unpaid (the card is still being retried);
 * - `GET /v1/billing/checkout?plan=` (no auth, the site's button) -> 303 to a Checkout without an
 *   account, 20 per IP per hour;
 * - `POST /v1/billing/portal` (bearer) -> `{ url }` of the Customer Portal; 404 `no_customer`.
 * A Stripe failure answers 502 `billing_unavailable`, a missing price or key 503.
 */
export function billingRoutes(deps: Deps): Hono<AppEnv> {
  const sitePerIp = new RateLimiter(20, HOUR_MS);
  const routes = new Hono<AppEnv>();

  routes.post("/billing/checkout", smallBody(), requireSession(deps), async (c) => {
    const body = await readJsonObject(c);
    const plan = body?.plan;
    if (!isBillingPlan(plan)) return c.json({ error: "bad_request" }, 400);
    const user = c.get("user");
    const sub = await subscriptionFor(deps.db, user.id);
    if (entitlement(sub, deps.now()).plan === "pro") return c.json({ error: "already_pro" }, 409);
    // Stripe keeps retrying the card of an unpaid subscription for weeks; a second one now
    // could charge the user twice. The app sends them to the Portal to update the card instead.
    if (sub && UNPAID_STATUSES.includes(sub.status)) return c.json({ error: "payment_pending" }, 409);
    const price = priceFor(plan, deps.config);
    if (!price) return unavailable(c, deps, "price_not_configured");

    try {
      const customerId = await ensureCustomer(deps, user);
      const session = await deps.stripe.checkout.sessions.create(
        checkoutParams(plan, price, deps.config.publicSiteUrl, { userId: user.id, customerId }),
      );
      if (!session.url) return failed(c, deps, new Error("checkout session without url"));
      return c.json({ url: session.url });
    } catch (error) {
      return failed(c, deps, error);
    }
  });

  routes.get("/billing/checkout", async (c) => {
    if (!sitePerIp.take(clientIp(c), deps.now())) return c.json({ error: "rate_limited" }, 429);
    const plan = c.req.query("plan");
    if (!isBillingPlan(plan)) return c.json({ error: "bad_request" }, 400);
    const price = priceFor(plan, deps.config);
    if (!price) return unavailable(c, deps, "price_not_configured");

    try {
      const session = await deps.stripe.checkout.sessions.create(checkoutParams(plan, price, deps.config.publicSiteUrl));
      if (!session.url) return failed(c, deps, new Error("checkout session without url"));
      return c.redirect(session.url, 303);
    } catch (error) {
      return failed(c, deps, error);
    }
  });

  routes.post("/billing/portal", requireSession(deps), async (c) => {
    const user = c.get("user");
    const row = await deps.db.one<{ stripe_customer_id: string | null }>("select stripe_customer_id from users where id = $1", [user.id]);
    if (!row?.stripe_customer_id) return c.json({ error: "no_customer" }, 404);
    try {
      const session = await deps.stripe.billingPortal.sessions.create({
        customer: row.stripe_customer_id,
        return_url: `${deps.config.publicSiteUrl}/pro/konto/`,
      });
      return c.json({ url: session.url });
    } catch (error) {
      return failed(c, deps, error);
    }
  });

  return routes;
}

/** The user's Stripe customer, created on the first Checkout. Two parallel first clicks keep the first one stored. */
async function ensureCustomer(deps: Deps, user: SessionUser): Promise<string> {
  const select = "select stripe_customer_id from users where id = $1";
  const row = await deps.db.one<{ stripe_customer_id: string | null }>(select, [user.id]);
  if (row?.stripe_customer_id) return row.stripe_customer_id;
  const customer = await deps.stripe.customers.create({ email: user.email, metadata: { user_id: user.id } });
  await deps.db.query("update users set stripe_customer_id = $2 where id = $1 and stripe_customer_id is null", [user.id, customer.id]);
  const stored = await deps.db.one<{ stripe_customer_id: string | null }>(select, [user.id]);
  return stored?.stripe_customer_id ?? customer.id;
}

function failed(c: Context<AppEnv>, deps: Deps, error: unknown) {
  if (error instanceof StripeNotConfiguredError) return unavailable(c, deps, "stripe_not_configured");
  deps.log.error({ reqId: c.get("reqId"), route: c.req.path, ...stripeErrorFields(error) }, "stripe call failed");
  return c.json({ error: "billing_unavailable" }, 502);
}

function unavailable(c: Context<AppEnv>, deps: Deps, reason: string) {
  deps.log.error({ reqId: c.get("reqId"), route: c.req.path, reason }, "billing not configured");
  return c.json({ error: "billing_unavailable" }, 503);
}
