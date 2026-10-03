import { beforeEach, describe, expect, it } from "vitest";
import type { Db } from "../src/db.js";
import { uuid } from "../src/lib/ids.js";
import { addUsage, monthKey, nextMonthStart, overAudioCap, overTokenCap, usageFor } from "../src/lib/usage.js";
import { testDb } from "./helpers.js";

describe("monthKey", () => {
  it("is the UTC month, also around midnight on New Year's Eve", () => {
    expect(monthKey(new Date("2026-12-31T23:30:00Z"))).toBe("2026-12");
    expect(monthKey(new Date("2027-01-01T00:30:00Z"))).toBe("2027-01");
    // 00:30 in Warsaw on 1 November is still October in UTC.
    expect(monthKey(new Date("2026-10-31T23:30:00Z"))).toBe("2026-10");
  });
});

describe("nextMonthStart", () => {
  it("is midnight UTC on the first day of the next month", () => {
    expect(nextMonthStart(new Date("2026-10-03T12:00:00Z")).toISOString()).toBe("2026-11-01T00:00:00.000Z");
    expect(nextMonthStart(new Date("2026-12-31T23:59:59Z")).toISOString()).toBe("2027-01-01T00:00:00.000Z");
  });
});

describe("caps", () => {
  const usage = (audioSeconds: number, aiTokens: number) => ({ audioSeconds, aiTokens });

  it("refuses audio when the request would go over the cap", () => {
    expect(overAudioCap(usage(0, 0), 72_000, 72_000)).toBe(false);
    expect(overAudioCap(usage(71_000, 0), 72_000, 1_000)).toBe(false);
    expect(overAudioCap(usage(71_000, 0), 72_000, 1_001)).toBe(true);
    expect(overAudioCap(usage(72_000, 0), 72_000, 1)).toBe(true);
    expect(overAudioCap(usage(0, 0), 0, 1)).toBe(true);
  });

  it("refuses AI once the tokens reached the cap (the next request's size is unknown)", () => {
    expect(overTokenCap(usage(0, 2_999_999), 3_000_000)).toBe(false);
    expect(overTokenCap(usage(0, 3_000_000), 3_000_000)).toBe(true);
    expect(overTokenCap(usage(0, 0), 0)).toBe(true);
  });
});

describe("usageFor / addUsage", () => {
  let db: Db;
  let userId: string;
  const now = new Date("2026-10-03T12:00:00Z");

  beforeEach(async () => {
    ({ db } = await testDb());
    userId = uuid();
    await db.query("insert into users (id, email) values ($1, $2)", [userId, "anna@example.pl"]);
  });

  it("is zero for a month with no requests", async () => {
    expect(await usageFor(db, userId, now)).toEqual({ audioSeconds: 0, aiTokens: 0 });
  });

  it("adds to this month's counters and keeps months apart", async () => {
    await addUsage(db, userId, now, { audioSeconds: 90 });
    await addUsage(db, userId, now, { aiTokens: 1_200 });
    await addUsage(db, userId, now, { audioSeconds: 30, aiTokens: 800 });
    expect(await usageFor(db, userId, now)).toEqual({ audioSeconds: 120, aiTokens: 2_000 });

    const november = new Date("2026-11-01T00:00:01Z");
    expect(await usageFor(db, userId, november)).toEqual({ audioSeconds: 0, aiTokens: 0 });
    await addUsage(db, userId, november, { aiTokens: 5 });
    expect(await usageFor(db, userId, november)).toEqual({ audioSeconds: 0, aiTokens: 5 });
    expect(await usageFor(db, userId, now)).toEqual({ audioSeconds: 120, aiTokens: 2_000 });
  });

  it("ignores negative, fractional and non-finite deltas", async () => {
    await addUsage(db, userId, now, { audioSeconds: -10, aiTokens: Number.NaN });
    await addUsage(db, userId, now, { audioSeconds: 1.2, aiTokens: 2.5 });
    expect(await usageFor(db, userId, now)).toEqual({ audioSeconds: 2, aiTokens: 3 });
  });

  it("counts parallel additions without losing any", async () => {
    await Promise.all(Array.from({ length: 10 }, () => addUsage(db, userId, now, { aiTokens: 100 })));
    expect((await usageFor(db, userId, now)).aiTokens).toBe(1_000);
  });
});
