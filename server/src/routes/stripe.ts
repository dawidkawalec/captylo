import { Hono } from "hono";
import type Stripe from "stripe";
import type { AppEnv, Deps } from "../app.js";
import { smallBody } from "../lib/http.js";
import { applyStripeEvent, prefetchForEvent, type EventOutcome } from "../lib/stripe-events.js";
import { stripeErrorFields } from "../lib/stripe.js";

/**
 * Outcomes worth a warning: an event that should have matched an account and did not, or a
 * second subscription the owner has to refund or cancel by hand in the Dashboard.
 */
const WARN_OUTCOMES: ReadonlySet<EventOutcome | "duplicate"> = new Set(["unknown_customer", "no_user", "duplicate_subscription", "replaced_unpaid"]);

/**
 * `POST /v1/stripe/webhook`: verifies the signature over the raw body, then applies the event
 * once (`stripe_events`) in one transaction. A failure answers 500 and records nothing, so
 * Stripe delivers the event again. The log line holds the event id, type and outcome only.
 */
export function stripeRoutes(deps: Deps): Hono<AppEnv> {
  const routes = new Hono<AppEnv>();

  routes.post("/stripe/webhook", smallBody(1024 * 1024), async (c) => {
    const reqId = c.get("reqId");
    const signature = c.req.header("Stripe-Signature");
    const payload = await c.req.text();
    let event: Stripe.Event;
    try {
      if (!signature) throw new Error("missing signature");
      event = deps.stripe.webhooks.constructEvent(payload, signature, deps.config.stripeWebhookSecret);
    } catch (error) {
      deps.log.warn({ reqId, reason: error instanceof Error ? error.name : "unknown" }, "stripe webhook refused");
      return c.json({ error: "bad_signature" }, 400);
    }

    const seen = await deps.db.one("select id from stripe_events where id = $1", [event.id]);
    let outcome: EventOutcome | "duplicate" = "duplicate";
    if (!seen) {
      let prefetched;
      try {
        prefetched = await prefetchForEvent(deps.stripe, event);
      } catch (error) {
        deps.log.error({ reqId, eventId: event.id, event: event.type, ...stripeErrorFields(error) }, "stripe webhook fetch failed");
        return c.json({ error: "internal", requestId: reqId }, 500);
      }
      const now = deps.now();
      outcome = await deps.db.tx(async (t) => {
        const fresh = await t.one("insert into stripe_events (id, received_at) values ($1, $2) on conflict (id) do nothing returning id", [
          event.id,
          now,
        ]);
        if (!fresh) return "duplicate" as const;
        return applyStripeEvent(t, deps.config, event, prefetched, now);
      });
    }

    const fields = { reqId, eventId: event.id, event: event.type, outcome };
    if (WARN_OUTCOMES.has(outcome)) deps.log.warn(fields, "stripe event");
    else deps.log.info(fields, "stripe event");
    return c.json({ received: true });
  });

  return routes;
}
