import { describe, expect, it } from "vitest";
import { entitlement, PAST_DUE_GRACE_MS, type SubscriptionRow } from "../src/lib/entitlement.js";

const now = new Date("2026-10-03T12:00:00Z");
const day = 24 * 60 * 60_000;

function sub(overrides: Partial<SubscriptionRow> = {}): SubscriptionRow {
  return {
    status: "active",
    plan: "yearly",
    current_period_start: new Date("2026-10-03T12:00:00Z"),
    current_period_end: new Date("2027-10-03T12:00:00Z"),
    cancel_at_period_end: false,
    ...overrides,
  };
}

/**
 * A subscription whose renewal charge failed `ago` ms before `now`: Stripe moves the period
 * when it creates the renewal invoice, so the unpaid period starts then and ends a year later.
 */
function failedRenewal(ago: number): SubscriptionRow {
  const start = new Date(now.getTime() - ago);
  const end = new Date(start.getTime() + 365 * day);
  return sub({ status: "past_due", current_period_start: start, current_period_end: end });
}

describe("entitlement", () => {
  it("is Free with no subscription", () => {
    expect(entitlement(undefined, now)).toEqual({ plan: "free", status: null, periodEnd: null, cancelAtPeriodEnd: false });
  });

  it("is Pro while active or trialing and reports the period", () => {
    const active = sub({ cancel_at_period_end: true });
    expect(entitlement(active, now)).toEqual({
      plan: "pro",
      status: "active",
      periodEnd: active.current_period_end,
      cancelAtPeriodEnd: true,
    });
    expect(entitlement(sub({ status: "trialing" }), now).plan).toBe("pro");
  });

  it("keeps past_due Pro for three days from the start of the unpaid period, then Free", () => {
    expect(entitlement(failedRenewal(2 * day), now).plan).toBe("pro");
    expect(entitlement(failedRenewal(PAST_DUE_GRACE_MS), now).plan).toBe("pro");
    const result = entitlement(failedRenewal(PAST_DUE_GRACE_MS + 1), now);
    expect(result.plan).toBe("free");
    expect(result.status).toBe("past_due");
  });

  it("never stretches the past_due grace to the end of the unpaid period", () => {
    const row = failedRenewal(4 * day);
    expect(row.current_period_end.getTime()).toBeGreaterThan(now.getTime());
    expect(entitlement(row, now).plan).toBe("free");
  });

  it.each(["canceled", "unpaid", "incomplete", "incomplete_expired", "paused", "something_new"])("is Free when %s", (status) => {
    const result = entitlement(sub({ status }), now);
    expect(result.plan).toBe("free");
    expect(result.status).toBe(status);
  });

  it("reads period dates stored as text (a raw driver row)", () => {
    const row = {
      ...sub({ status: "past_due" }),
      current_period_start: "2026-10-01T12:00:00Z" as unknown as Date,
      current_period_end: "2026-11-01T12:00:00Z" as unknown as Date,
    };
    const result = entitlement(row, now);
    expect(result.plan).toBe("pro");
    expect(result.periodEnd?.toISOString()).toBe("2026-11-01T12:00:00.000Z");
  });
});
