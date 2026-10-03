import Stripe from "stripe";
import { beforeEach, describe, expect, it } from "vitest";
import { buildApp } from "../src/app.js";
import { createStripe, StripeNotConfiguredError } from "../src/lib/stripe.js";
import { signIn, stripeFixture, testDeps, type TestDeps } from "./helpers.js";

const minute = 60_000;
const day = 24 * 60 * minute;

let deps: TestDeps;
let app: ReturnType<typeof buildApp>;

beforeEach(async () => {
  deps = await testDeps();
  app = buildApp(deps);
  deps.stripe.subscriptionsById.set("sub_test_app", subscriptionOf("subscription-updated-active"));
  deps.stripe.subscriptionsById.set("sub_test_site", {
    ...subscriptionOf("subscription-updated-active"),
    id: "sub_test_site",
    customer: "cus_test_site",
    metadata: { plan: "monthly" },
  });
});

function subscriptionOf(fixture: string): Stripe.Subscription {
  return stripeFixture(fixture).data.object as Stripe.Subscription;
}

/** `signature: null` sends no `Stripe-Signature` header. */
function webhook(event: unknown, signature: string | null = "test") {
  return app.request("/v1/stripe/webhook", {
    method: "POST",
    headers: { "Content-Type": "application/json", ...(signature === null ? {} : { "Stripe-Signature": signature }) },
    body: typeof event === "string" ? event : JSON.stringify(event),
  });
}

/** A fixture with a new event id and `created`, and the object's fields patched. */
function eventFrom(fixture: string, id: string, created: number, patch: Record<string, unknown> = {}): Stripe.Event {
  // A plain record on purpose: spreading the Stripe.Event union makes tsc crawl.
  const event = stripeFixture(fixture) as unknown as { id: string; created: number; data: { object: Record<string, unknown> } };
  event.id = id;
  event.created = created;
  Object.assign(event.data.object, patch);
  return event as unknown as Stripe.Event;
}

async function appCheckoutFor(email: string): Promise<{ token: string; id: string }> {
  const token = await signIn(app, deps.mailer, email);
  const row = await deps.db.one<{ id: string }>("select id from users where email = $1", [email]);
  const event = stripeFixture("checkout-completed-app");
  (event.data.object as Stripe.Checkout.Session).client_reference_id = row!.id;
  const res = await webhook(event);
  expect(res.status).toBe(200);
  return { token, id: row!.id };
}

async function me(token: string) {
  const res = await app.request("/v1/me", { headers: { Authorization: `Bearer ${token}` } });
  expect(res.status).toBe(200);
  return (await res.json()) as { email: string; plan: string; status: string | null; periodEnd: string | null; cancelAtPeriodEnd: boolean };
}

function portal(token: string) {
  return app.request("/v1/billing/portal", { method: "POST", headers: { Authorization: `Bearer ${token}` } });
}

async function customerOf(email: string): Promise<string | null | undefined> {
  const row = await deps.db.one<{ stripe_customer_id: string | null }>("select stripe_customer_id from users where email = $1", [email]);
  return row?.stripe_customer_id;
}

async function count(table: string): Promise<number> {
  const row = await deps.db.one<{ n: number }>(`select count(*)::int as n from ${table}`);
  return row?.n ?? 0;
}

describe("POST /v1/stripe/webhook: signature", () => {
  it("answers 400 to a wrong or missing signature and records nothing", async () => {
    const event = stripeFixture("subscription-updated-active");
    for (const signature of ["t=1,v1=forged", null]) {
      const res = await webhook(event, signature);
      expect(res.status).toBe(400);
      expect(await res.json()).toEqual({ error: "bad_signature" });
    }
    expect(await count("stripe_events")).toBe(0);
  });

  it("verifies against the configured webhook secret", async () => {
    deps = await testDeps({ STRIPE_WEBHOOK_SECRET: "whsec_configured_for_test" });
    app = buildApp(deps);
    await webhook(stripeFixture("subscription-updated-active"));
    const call = deps.stripe.callsOf("webhooks.constructEvent")[0];
    expect(call?.params).toEqual({ header: "test", secret: "whsec_configured_for_test" });
  });
});

describe("checkout.session.completed", () => {
  it("from the app links the customer to the signed-in user and makes them Pro", async () => {
    const { token, id } = await appCheckoutFor("anna@example.pl");
    const user = await deps.db.one<{ stripe_customer_id: string }>("select stripe_customer_id from users where id = $1", [id]);
    expect(user?.stripe_customer_id).toBe("cus_test_app");
    expect(deps.stripe.callsOf("subscriptions.retrieve").map((c) => c.params)).toEqual([{ id: "sub_test_app" }]);
    expect(await me(token)).toMatchObject({
      email: "anna@example.pl",
      plan: "pro",
      status: "active",
      periodEnd: "2027-10-03T12:00:00.000Z",
      cancelAtPeriodEnd: false,
    });
    const sub = await deps.db.one<{ plan: string; event_created: number; stripe_subscription_id: string }>(
      "select plan, event_created, stripe_subscription_id from subscriptions where user_id = $1",
      [id],
    );
    expect(sub).toEqual({ plan: "yearly", event_created: 1791028800, stripe_subscription_id: "sub_test_app" });
  });

  it("from the site creates the account by e-mail (any case); signing in later finds Pro", async () => {
    const res = await webhook(stripeFixture("checkout-completed-site"));
    expect(res.status).toBe(200);
    const users = await deps.db.query<{ email: string; stripe_customer_id: string }>("select email, stripe_customer_id from users");
    expect(users).toEqual([{ email: "ola.nowak@example.pl", stripe_customer_id: "cus_test_site" }]);

    const token = await signIn(app, deps.mailer, "OLA.NOWAK@example.pl");
    expect(await me(token)).toMatchObject({ email: "ola.nowak@example.pl", plan: "pro", status: "active" });
    const sub = await deps.db.one<{ plan: string }>("select plan from subscriptions");
    expect(sub?.plan).toBe("monthly");
    expect(await count("users")).toBe(1);
  });

  it("from the site attaches to an existing account with the same address", async () => {
    const token = await signIn(app, deps.mailer, "ola.nowak@example.pl");
    expect((await me(token)).plan).toBe("free");
    expect((await webhook(stripeFixture("checkout-completed-site"))).status).toBe(200);
    expect(await count("users")).toBe(1);
    expect((await me(token)).plan).toBe("pro");
  });

  it("from the site moves an account with an abandoned app Checkout to the paying customer, so the Portal shows the subscription", async () => {
    const token = await signIn(app, deps.mailer, "ola.nowak@example.pl");
    const opened = await app.request("/v1/billing/checkout", {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}` },
      body: JSON.stringify({ plan: "yearly" }),
    });
    expect(opened.status).toBe(200);
    expect(await customerOf("ola.nowak@example.pl")).toBe("cus_fake_1");

    expect((await webhook(stripeFixture("checkout-completed-site"))).status).toBe(200);
    expect(await customerOf("ola.nowak@example.pl")).toBe("cus_test_site");
    expect((await portal(token)).status).toBe(200);
    expect(deps.stripe.callsOf("billingPortal.sessions.create").map((c) => (c.params as { customer: string }).customer)).toEqual(["cus_test_site"]);
  });

  it("from the site after a canceled app subscription switches the Portal to the new customer", async () => {
    const { token } = await appCheckoutFor("ola.nowak@example.pl");
    expect(await customerOf("ola.nowak@example.pl")).toBe("cus_test_app");
    await webhook(stripeFixture("subscription-deleted"));
    expect((await me(token)).plan).toBe("free");

    expect((await webhook(eventFrom("checkout-completed-site", "evt_test_site_again", 1791030000))).status).toBe(200);
    expect(await me(token)).toMatchObject({ plan: "pro", status: "active" });
    expect(await customerOf("ola.nowak@example.pl")).toBe("cus_test_site");
    await portal(token);
    expect(deps.stripe.callsOf("billingPortal.sessions.create").map((c) => (c.params as { customer: string }).customer)).toEqual(["cus_test_site"]);
  });

  it("never takes a customer another account already holds", async () => {
    await signIn(app, deps.mailer, "anna@example.pl");
    await deps.db.query("update users set stripe_customer_id = 'cus_test_site' where email = 'anna@example.pl'");
    const { id } = await appCheckoutFor("ola.nowak@example.pl");
    await webhook(stripeFixture("subscription-deleted"));
    const event = eventFrom("checkout-completed-site", "evt_test_site_held", 1791030000, { client_reference_id: id });
    expect((await webhook(event)).status).toBe(200);
    expect(await customerOf("anna@example.pl")).toBe("cus_test_site");
    expect(await customerOf("ola.nowak@example.pl")).toBe("cus_test_app");
  });

  it("from the site for an account that is already Pro keeps the paid subscription and its customer", async () => {
    const { token } = await appCheckoutFor("ola.nowak@example.pl");
    expect((await webhook(eventFrom("checkout-completed-site", "evt_test_site_dup", 1791030000))).status).toBe(200);

    const sub = await deps.db.one<{ stripe_subscription_id: string }>("select stripe_subscription_id from subscriptions");
    expect(sub?.stripe_subscription_id).toBe("sub_test_app");
    expect(await customerOf("ola.nowak@example.pl")).toBe("cus_test_app");
    expect(deps.log.lines.some((l) => l.level === "warn" && l.fields.outcome === "duplicate_subscription")).toBe(true);

    // The original subscription's later events still reach the account; the Portal still opens it.
    await webhook(eventFrom("subscription-updated-active", "evt_test_orig_later", 1791030600, { cancel_at_period_end: true }));
    expect(await me(token)).toMatchObject({ plan: "pro", status: "active", cancelAtPeriodEnd: true });
    await portal(token);
    expect(deps.stripe.callsOf("billingPortal.sessions.create").map((c) => (c.params as { customer: string }).customer)).toEqual(["cus_test_app"]);

    // The duplicate's own events change nothing.
    const dupUpdate = eventFrom("subscription-updated-active", "evt_test_dup_update", 1791031200, { id: "sub_test_site", customer: "cus_test_site" });
    expect((await webhook(dupUpdate)).status).toBe(200);
    expect((await deps.db.one<{ stripe_subscription_id: string }>("select stripe_subscription_id from subscriptions"))?.stripe_subscription_id).toBe("sub_test_app");
  });

  it("from the site after an unpaid (past_due) subscription takes the paid one and warns about the old one", async () => {
    const { token } = await appCheckoutFor("ola.nowak@example.pl");
    await webhook(stripeFixture("subscription-updated-past-due"));
    expect((await webhook(eventFrom("checkout-completed-site", "evt_test_site_after_unpaid", 1791030000))).status).toBe(200);

    expect(await me(token)).toMatchObject({ plan: "pro", status: "active" });
    expect((await deps.db.one<{ stripe_subscription_id: string }>("select stripe_subscription_id from subscriptions"))?.stripe_subscription_id).toBe("sub_test_site");
    expect(await customerOf("ola.nowak@example.pl")).toBe("cus_test_site");
    expect(deps.log.lines.some((l) => l.level === "warn" && l.fields.outcome === "replaced_unpaid")).toBe(true);
  });

  it("from the site after a subscription set to end takes the new one", async () => {
    const { token } = await appCheckoutFor("ola.nowak@example.pl");
    await webhook(eventFrom("subscription-updated-active", "evt_test_cancel_end", 1791029200, { cancel_at_period_end: true }));
    expect((await webhook(eventFrom("checkout-completed-site", "evt_test_site_after_end", 1791030000))).status).toBe(200);
    expect(await me(token)).toMatchObject({ plan: "pro", status: "active", cancelAtPeriodEnd: false });
    expect(await customerOf("ola.nowak@example.pl")).toBe("cus_test_site");
  });

  it("falls back to the e-mail when the reference is not a known user", async () => {
    const event = stripeFixture("checkout-completed-app");
    (event.data.object as Stripe.Checkout.Session).client_reference_id = "not-a-uuid";
    expect((await webhook(event)).status).toBe(200);
    const users = await deps.db.query<{ email: string }>("select email from users");
    expect(users).toEqual([{ email: "anna@example.pl" }]);
    expect(await count("subscriptions")).toBe(1);
  });

  it("ignores a one-off payment (the coffee link on the same account)", async () => {
    const res = await webhook(stripeFixture("checkout-completed-payment"));
    expect(res.status).toBe(200);
    expect(await count("users")).toBe(0);
    expect(deps.stripe.callsOf("subscriptions.retrieve")).toHaveLength(0);
  });

  it("answers 500 and records nothing when Stripe cannot be reached, so Stripe retries", async () => {
    deps.stripe.failWith = Object.assign(new Error("connection reset"), { type: "StripeConnectionError" });
    const res = await webhook(stripeFixture("checkout-completed-site"));
    expect(res.status).toBe(500);
    expect(await count("stripe_events")).toBe(0);
    expect(await count("users")).toBe(0);

    deps.stripe.failWith = undefined;
    expect((await webhook(stripeFixture("checkout-completed-site"))).status).toBe(200);
    expect(await count("subscriptions")).toBe(1);
  });
});

describe("events are applied once and in order", () => {
  it("applies the same event id once", async () => {
    const event = stripeFixture("checkout-completed-site");
    expect((await webhook(event)).status).toBe(200);
    expect((await webhook(event)).status).toBe(200);
    expect(deps.stripe.callsOf("subscriptions.retrieve")).toHaveLength(1);
    expect(await count("stripe_events")).toBe(1);
    expect(await count("users")).toBe(1);
  });

  it("keeps a deleted subscription canceled when an older update arrives late", async () => {
    const { token } = await appCheckoutFor("anna@example.pl");
    expect((await webhook(stripeFixture("subscription-deleted"))).status).toBe(200);
    expect(await me(token)).toMatchObject({ plan: "free", status: "canceled" });

    expect((await webhook(stripeFixture("subscription-updated-active"))).status).toBe(200);
    expect(await me(token)).toMatchObject({ plan: "free", status: "canceled" });
  });

  it("keeps an active subscription when its created (incomplete) event arrives late in the same second", async () => {
    const { token } = await appCheckoutFor("anna@example.pl");
    await webhook(eventFrom("subscription-updated-active", "evt_test_active_tie", 1791028800));
    const created = eventFrom("subscription-updated-active", "evt_test_created_tie", 1791028800, { status: "incomplete" });
    (created as { type: string }).type = "customer.subscription.created";
    expect((await webhook(created)).status).toBe(200);
    expect(await me(token)).toMatchObject({ plan: "pro", status: "active" });
  });

  it("keeps the paid subscription when a second one of the same customer turns active", async () => {
    const { token } = await appCheckoutFor("anna@example.pl");
    const second = eventFrom("subscription-updated-active", "evt_test_second_sub", 1791030000, { id: "sub_test_second" });
    (second as { type: string }).type = "customer.subscription.created";
    expect((await webhook(second)).status).toBe(200);
    expect(await me(token)).toMatchObject({ plan: "pro", status: "active" });
    expect((await deps.db.one<{ stripe_subscription_id: string }>("select stripe_subscription_id from subscriptions"))?.stripe_subscription_id).toBe("sub_test_app");
    expect(deps.log.lines.some((l) => l.level === "warn" && l.fields.outcome === "duplicate_subscription")).toBe(true);
  });

  it("never revives a canceled subscription, even from a newer event", async () => {
    const { token } = await appCheckoutFor("anna@example.pl");
    await webhook(stripeFixture("subscription-deleted"));
    await webhook(eventFrom("subscription-updated-active", "evt_test_revive", 1791030000));
    expect((await me(token)).status).toBe("canceled");
  });

  it("takes a new subscription after a canceled one, and a late event of the old one does not undo it", async () => {
    const { token } = await appCheckoutFor("anna@example.pl");
    await webhook(stripeFixture("subscription-deleted"));
    expect((await me(token)).plan).toBe("free");

    const renewed = eventFrom("subscription-updated-active", "evt_test_new_sub", 1791030000, { id: "sub_test_new", metadata: { plan: "monthly" } });
    (renewed as { type: string }).type = "customer.subscription.created";
    expect((await webhook(renewed)).status).toBe(200);
    expect(await me(token)).toMatchObject({ plan: "pro", status: "active" });

    await webhook(eventFrom("subscription-deleted", "evt_test_old_late", 1791030600));
    expect(await me(token)).toMatchObject({ plan: "pro", status: "active" });
    const sub = await deps.db.one<{ stripe_subscription_id: string; plan: string }>("select stripe_subscription_id, plan from subscriptions");
    expect(sub).toEqual({ stripe_subscription_id: "sub_test_new", plan: "monthly" });
  });
});

describe("customer.subscription.*", () => {
  it("keeps past_due Pro for 3 days from the failed renewal, not until the unpaid period ends", async () => {
    const { token } = await appCheckoutFor("anna@example.pl");
    expect((await webhook(stripeFixture("subscription-updated-past-due"))).status).toBe(200);
    // Stripe moved the period to 2026-10-03 11:00 - 2026-11-03 11:00 when it created the
    // renewal invoice, then the charge failed; the clock is at 12:00 on 2026-10-03.
    expect(await me(token)).toMatchObject({ plan: "pro", status: "past_due", periodEnd: "2026-11-03T11:00:00.000Z" });
    deps.clock.set("2026-10-05T11:00:00Z");
    expect((await me(token)).plan).toBe("pro");
    deps.clock.set("2026-10-06T10:59:00Z");
    expect((await me(token)).plan).toBe("pro");
    deps.clock.set("2026-10-06T11:01:00Z");
    expect(await me(token)).toMatchObject({ plan: "free", status: "past_due" });
    deps.clock.set("2026-10-07T11:00:00Z");
    expect(await me(token)).toMatchObject({ plan: "free", status: "past_due", periodEnd: "2026-11-03T11:00:00.000Z" });
  });

  it("stores the start of the current period", async () => {
    await appCheckoutFor("anna@example.pl");
    await webhook(stripeFixture("subscription-updated-past-due"));
    const sub = await deps.db.one<{ current_period_start: Date }>("select current_period_start from subscriptions");
    expect(new Date(sub!.current_period_start).toISOString()).toBe("2026-10-03T11:00:00.000Z");
  });

  it("takes the plan from the price when the metadata has none", async () => {
    await appCheckoutFor("anna@example.pl");
    await webhook(stripeFixture("subscription-updated-past-due"));
    const sub = await deps.db.one<{ plan: string }>("select plan from subscriptions");
    expect(sub?.plan).toBe("monthly");
  });

  it("records cancel_at_period_end", async () => {
    const { token } = await appCheckoutFor("anna@example.pl");
    await webhook(eventFrom("subscription-updated-active", "evt_test_cancel_later", 1791029200, { cancel_at_period_end: true }));
    expect(await me(token)).toMatchObject({ plan: "pro", cancelAtPeriodEnd: true });
  });

  it("ignores a subscription of an unknown customer with a warning", async () => {
    const res = await webhook(stripeFixture("subscription-updated-active"));
    expect(res.status).toBe(200);
    expect(await count("subscriptions")).toBe(0);
    expect(deps.log.lines.some((l) => l.level === "warn" && l.fields.outcome === "unknown_customer")).toBe(true);
  });

  it("ignores a subscription to a price that is not Captylo Pro", async () => {
    await appCheckoutFor("anna@example.pl");
    await deps.db.query("delete from subscriptions");
    const foreign = eventFrom("subscription-updated-active", "evt_test_foreign", 1791029200, {
      metadata: {},
      items: { object: "list", data: [{ id: "si_x", current_period_end: 1822564800, price: { id: "price_test_other" } }] },
    });
    expect((await webhook(foreign)).status).toBe(200);
    expect(await count("subscriptions")).toBe(0);
  });

  it("falls back to the top-level period of older payloads", async () => {
    const { token } = await appCheckoutFor("anna@example.pl");
    const old = eventFrom("subscription-updated-active", "evt_test_old_shape", 1791029200, {
      current_period_start: 1791028800,
      current_period_end: 1793707200,
      items: { object: "list", data: [{ id: "si_x", price: { id: "price_test_yearly" } }] },
    });
    await webhook(old);
    expect((await me(token)).periodEnd).toBe("2026-11-03T12:00:00.000Z");
    const sub = await deps.db.one<{ current_period_start: Date }>("select current_period_start from subscriptions");
    expect(new Date(sub!.current_period_start).toISOString()).toBe("2026-10-03T12:00:00.000Z");
  });

  it("ignores a subscription without a period start", async () => {
    await appCheckoutFor("anna@example.pl");
    const before = await deps.db.one("select * from subscriptions");
    const broken = eventFrom("subscription-updated-active", "evt_test_no_start", 1791029200, {
      items: { object: "list", data: [{ id: "si_x", current_period_end: 1822564800, price: { id: "price_test_yearly" } }] },
    });
    expect((await webhook(broken)).status).toBe(200);
    expect(await deps.db.one("select * from subscriptions")).toEqual(before);
  });
});

describe("other events", () => {
  it.each(["invoice.paid", "invoice.payment_failed", "customer.created", "charge.refunded"])("answers 200 to %s and changes nothing", async (type) => {
    const { token } = await appCheckoutFor("anna@example.pl");
    const before = await me(token);
    const event = { id: `evt_test_${type}`, object: "event", created: 1791029999, type, data: { object: { id: "in_test_1", customer: "cus_test_app" } } };
    expect((await webhook(event)).status).toBe(200);
    expect(await me(token)).toEqual(before);
  });

  it("never logs an e-mail address", async () => {
    await appCheckoutFor("anna@example.pl");
    await webhook(stripeFixture("checkout-completed-site"));
    await webhook(stripeFixture("subscription-deleted"));
    expect(JSON.stringify(deps.log.lines)).not.toMatch(/@/);
  });
});

describe("the production Stripe client", () => {
  // Built from parts so no secret-looking literal sits in the repo; nothing here reaches the network.
  const secret = ["whsec", "unit", "test", "only"].join("_");
  const key = ["sk", "test", "offline", "unit"].join("_");

  it("accepts a correctly signed body and refuses a tampered one", () => {
    const client = createStripe({ stripeSecretKey: key });
    const payload = JSON.stringify(stripeFixture("subscription-deleted"));
    const header = Stripe.webhooks.generateTestHeaderString({ payload, secret });
    expect(client.webhooks.constructEvent(payload, header, secret).id).toBe("evt_test_sub_deleted");
    expect(() => client.webhooks.constructEvent(payload.replace("canceled", "active"), header, secret)).toThrow();
    expect(() => client.webhooks.constructEvent(payload, header, "whsec_other")).toThrow();
  });

  it("refuses every call when no key is configured", async () => {
    const client = createStripe({ stripeSecretKey: "" });
    await expect(client.customers.create({ email: "x@example.pl" })).rejects.toBeInstanceOf(StripeNotConfiguredError);
    expect(() => client.webhooks.constructEvent("{}", "t=1,v1=x", "")).toThrow(StripeNotConfiguredError);
  });
});
