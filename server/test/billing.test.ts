import type Stripe from "stripe";
import { beforeEach, describe, expect, it } from "vitest";
import { buildApp } from "../src/app.js";
import { signIn, testDeps, testPrices, type TestDeps } from "./helpers.js";

let deps: TestDeps;
let app: ReturnType<typeof buildApp>;

beforeEach(async () => {
  deps = await testDeps();
  app = buildApp(deps);
});

function checkout(token: string | undefined, body: unknown) {
  return app.request("/v1/billing/checkout", {
    method: "POST",
    headers: { "Content-Type": "application/json", ...(token ? { Authorization: `Bearer ${token}` } : {}) },
    body: JSON.stringify(body),
  });
}

function siteCheckout(query: string, ip = "198.51.100.4") {
  return app.request(`/v1/billing/checkout${query}`, { headers: { "X-Forwarded-For": ip } });
}

function portal(token?: string) {
  return app.request("/v1/billing/portal", { method: "POST", headers: token ? { Authorization: `Bearer ${token}` } : {} });
}

async function userId(email: string): Promise<string> {
  const row = await deps.db.one<{ id: string }>("select id from users where email = $1", [email]);
  if (!row) throw new Error("no such user");
  return row.id;
}

async function giveSubscription(email: string, status: string, periodEnd = "2027-10-03T12:00:00Z"): Promise<void> {
  await deps.db.query(
    `insert into subscriptions (user_id, stripe_subscription_id, status, plan, current_period_start, current_period_end, cancel_at_period_end, event_created)
     values ($1, 'sub_test_given', $2, 'yearly', $3::timestamptz - interval '1 year', $3, false, 1)`,
    [await userId(email), status, periodEnd],
  );
}

function lastCheckoutParams(): Stripe.Checkout.SessionCreateParams {
  const call = deps.stripe.callsOf("checkout.sessions.create").at(-1);
  if (!call) throw new Error("no checkout session created");
  return call.params as Stripe.Checkout.SessionCreateParams;
}

function logsText(): string {
  return JSON.stringify(deps.log.lines);
}

describe("POST /v1/billing/checkout (from the app)", () => {
  it("needs a session", async () => {
    expect((await checkout(undefined, { plan: "yearly" })).status).toBe(401);
    expect(deps.stripe.calls).toHaveLength(0);
  });

  it("creates the Stripe customer once, stores it and opens a Checkout for the signed-in user", async () => {
    const token = await signIn(app, deps.mailer, "anna@example.pl");
    const id = await userId("anna@example.pl");

    const res = await checkout(token, { plan: "yearly" });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ url: "https://checkout.stripe.com/c/pay/cs_fake_1" });

    expect(deps.stripe.callsOf("customers.create").map((c) => c.params)).toEqual([{ email: "anna@example.pl", metadata: { user_id: id } }]);
    const stored = await deps.db.one<{ stripe_customer_id: string }>("select stripe_customer_id from users where id = $1", [id]);
    expect(stored?.stripe_customer_id).toBe("cus_fake_1");

    expect(lastCheckoutParams()).toEqual({
      mode: "subscription",
      customer: "cus_fake_1",
      client_reference_id: id,
      line_items: [{ price: testPrices.yearly, quantity: 1 }],
      allow_promotion_codes: true,
      automatic_tax: { enabled: true },
      customer_update: { address: "auto", name: "auto" },
      tax_id_collection: { enabled: true },
      billing_address_collection: "auto",
      locale: "auto",
      success_url: "https://captylo.com/pro/dziekujemy/?from=app",
      cancel_url: "https://captylo.com/#cennik",
      subscription_data: { metadata: { plan: "yearly" } },
    });

    const again = await checkout(token, { plan: "monthly" });
    expect(again.status).toBe(200);
    expect(deps.stripe.callsOf("customers.create")).toHaveLength(1);
    expect(lastCheckoutParams().customer).toBe("cus_fake_1");
    expect(lastCheckoutParams().line_items).toEqual([{ price: testPrices.monthly, quantity: 1 }]);
    expect(lastCheckoutParams().subscription_data).toEqual({ metadata: { plan: "monthly" } });
  });

  it("refuses an unknown plan", async () => {
    const token = await signIn(app, deps.mailer, "anna@example.pl");
    for (const body of [{ plan: "weekly" }, {}, { plan: 1 }]) {
      const res = await checkout(token, body);
      expect(res.status).toBe(400);
      expect(await res.json()).toEqual({ error: "bad_request" });
    }
    expect(deps.stripe.calls).toHaveLength(0);
  });

  it("answers 409 already_pro to a Pro user, but lets a lapsed one buy again", async () => {
    const token = await signIn(app, deps.mailer, "anna@example.pl");
    await giveSubscription("anna@example.pl", "active");
    const res = await checkout(token, { plan: "monthly" });
    expect(res.status).toBe(409);
    expect(await res.json()).toEqual({ error: "already_pro" });
    expect(deps.stripe.calls).toHaveLength(0);

    await deps.db.query("update subscriptions set status = 'canceled'");
    expect((await checkout(token, { plan: "monthly" })).status).toBe(200);
  });

  it.each(["past_due", "unpaid"])("answers 409 payment_pending while a %s subscription past the grace may still be charged", async (status) => {
    const token = await signIn(app, deps.mailer, "anna@example.pl");
    // The period started a month ago, so the 3-day past_due grace is over and the plan is Free.
    await giveSubscription("anna@example.pl", status, "2026-11-01T00:00:00Z");
    await deps.db.query("update subscriptions set current_period_start = '2026-09-20T00:00:00Z'");
    const me = await app.request("/v1/me", { headers: { Authorization: `Bearer ${token}` } });
    expect(await me.json()).toMatchObject({ plan: "free", status });

    const res = await checkout(token, { plan: "yearly" });
    expect(res.status).toBe(409);
    expect(await res.json()).toEqual({ error: "payment_pending" });
    expect(deps.stripe.calls).toHaveLength(0);
  });

  it("answers 502 billing_unavailable when Stripe fails and logs no address", async () => {
    const token = await signIn(app, deps.mailer, "anna@example.pl");
    deps.stripe.failWith = Object.assign(new Error("Invalid email anna@example.pl"), { type: "StripeInvalidRequestError", code: "email_invalid" });
    const res = await checkout(token, { plan: "yearly" });
    expect(res.status).toBe(502);
    expect(await res.json()).toEqual({ error: "billing_unavailable" });
    expect(logsText()).not.toContain("anna@");
    expect(deps.log.lines.some((l) => l.level === "error" && l.fields.code === "email_invalid")).toBe(true);
  });

  it("answers 503 billing_unavailable when the price is not configured", async () => {
    deps = await testDeps({ STRIPE_PRICE_YEARLY: "" });
    app = buildApp(deps);
    const token = await signIn(app, deps.mailer, "anna@example.pl");
    const res = await checkout(token, { plan: "yearly" });
    expect(res.status).toBe(503);
    expect(await res.json()).toEqual({ error: "billing_unavailable" });
    expect(deps.stripe.calls).toHaveLength(0);
  });
});

describe("GET /v1/billing/checkout (from the site)", () => {
  it("redirects 303 to a Checkout with no customer, Stripe collects the address", async () => {
    const res = await siteCheckout("?plan=yearly");
    expect(res.status).toBe(303);
    expect(res.headers.get("Location")).toBe("https://checkout.stripe.com/c/pay/cs_fake_1");
    expect(deps.stripe.callsOf("customers.create")).toHaveLength(0);
    const params = lastCheckoutParams();
    expect(params).toEqual({
      mode: "subscription",
      line_items: [{ price: testPrices.yearly, quantity: 1 }],
      allow_promotion_codes: true,
      automatic_tax: { enabled: true },
      tax_id_collection: { enabled: true },
      billing_address_collection: "auto",
      locale: "auto",
      success_url: "https://captylo.com/pro/dziekujemy/?from=site",
      cancel_url: "https://captylo.com/#cennik",
      subscription_data: { metadata: { plan: "yearly" } },
    });
    expect(params.customer).toBeUndefined();
    expect(params.client_reference_id).toBeUndefined();
  });

  it("uses the monthly price for plan=monthly", async () => {
    expect((await siteCheckout("?plan=monthly")).status).toBe(303);
    expect(lastCheckoutParams().line_items).toEqual([{ price: testPrices.monthly, quantity: 1 }]);
  });

  it("answers 400 to a bad or missing plan", async () => {
    for (const query of ["?plan=weekly", "", "?plan="]) {
      const res = await siteCheckout(query);
      expect(res.status).toBe(400);
      expect(await res.json()).toEqual({ error: "bad_request" });
    }
    expect(deps.stripe.calls).toHaveLength(0);
  });

  it("allows 20 per IP per hour", async () => {
    for (let i = 0; i < 20; i++) expect((await siteCheckout("?plan=yearly")).status).toBe(303);
    const limited = await siteCheckout("?plan=yearly");
    expect(limited.status).toBe(429);
    expect(await limited.json()).toEqual({ error: "rate_limited" });
    expect((await siteCheckout("?plan=yearly", "198.51.100.99")).status).toBe(303);
    deps.clock.advance(61 * 60_000);
    expect((await siteCheckout("?plan=yearly")).status).toBe(303);
  });

  it("answers 502 when Stripe fails", async () => {
    deps.stripe.failWith = Object.assign(new Error("boom"), { type: "StripeConnectionError" });
    const res = await siteCheckout("?plan=yearly");
    expect(res.status).toBe(502);
    expect(await res.json()).toEqual({ error: "billing_unavailable" });
  });
});

describe("POST /v1/billing/portal", () => {
  it("needs a session", async () => {
    expect((await portal()).status).toBe(401);
  });

  it("answers 404 no_customer to a user who never paid", async () => {
    const token = await signIn(app, deps.mailer, "anna@example.pl");
    const res = await portal(token);
    expect(res.status).toBe(404);
    expect(await res.json()).toEqual({ error: "no_customer" });
    expect(deps.stripe.calls).toHaveLength(0);
  });

  it("opens the Customer Portal for the user's customer", async () => {
    const token = await signIn(app, deps.mailer, "anna@example.pl");
    await deps.db.query("update users set stripe_customer_id = 'cus_test_app' where email = 'anna@example.pl'");
    const res = await portal(token);
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ url: "https://billing.stripe.com/p/session/fake_1" });
    expect(deps.stripe.callsOf("billingPortal.sessions.create").map((c) => c.params)).toEqual([
      { customer: "cus_test_app", return_url: "https://captylo.com/pro/konto/" },
    ]);
  });

  it("answers 502 when Stripe fails", async () => {
    const token = await signIn(app, deps.mailer, "anna@example.pl");
    await deps.db.query("update users set stripe_customer_id = 'cus_test_app' where email = 'anna@example.pl'");
    deps.stripe.failWith = Object.assign(new Error("boom"), { type: "StripeAPIError" });
    const res = await portal(token);
    expect(res.status).toBe(502);
    expect(await res.json()).toEqual({ error: "billing_unavailable" });
  });
});
