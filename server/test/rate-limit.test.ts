import { describe, expect, it } from "vitest";
import { RateLimiter } from "../src/lib/rate-limit.js";

const t0 = new Date("2026-10-03T12:00:00Z");
const at = (ms: number) => new Date(t0.getTime() + ms);
const minute = 60_000;

describe("RateLimiter", () => {
  it("allows up to the limit inside the window and refuses the next one", () => {
    const limiter = new RateLimiter(3, 15 * minute);
    expect(limiter.take("a", at(0))).toBe(true);
    expect(limiter.take("a", at(1 * minute))).toBe(true);
    expect(limiter.take("a", at(2 * minute))).toBe(true);
    expect(limiter.take("a", at(3 * minute))).toBe(false);
  });

  it("keeps keys apart", () => {
    const limiter = new RateLimiter(1, minute);
    expect(limiter.take("a", at(0))).toBe(true);
    expect(limiter.take("b", at(0))).toBe(true);
    expect(limiter.take("a", at(0))).toBe(false);
  });

  it("slides: a slot frees exactly when the oldest hit leaves the window", () => {
    const limiter = new RateLimiter(2, 15 * minute);
    expect(limiter.take("a", at(0))).toBe(true);
    expect(limiter.take("a", at(5 * minute))).toBe(true);
    expect(limiter.take("a", at(15 * minute - 1))).toBe(false);
    // The hit at 0 is out of the window at exactly 15 minutes.
    expect(limiter.take("a", at(15 * minute))).toBe(true);
    // Now the hits at 5 and 15 minutes fill it again.
    expect(limiter.take("a", at(16 * minute))).toBe(false);
    expect(limiter.take("a", at(20 * minute))).toBe(true);
  });

  it("does not count refused attempts, so hammering does not extend the lockout", () => {
    const limiter = new RateLimiter(1, 10 * minute);
    expect(limiter.take("a", at(0))).toBe(true);
    for (let i = 1; i < 10; i++) expect(limiter.take("a", at(i * minute))).toBe(false);
    expect(limiter.take("a", at(10 * minute))).toBe(true);
  });

  it("allows checks without recording, then records on demand", () => {
    const limiter = new RateLimiter(1, minute);
    expect(limiter.allows("a", at(0))).toBe(true);
    expect(limiter.allows("a", at(0))).toBe(true);
    limiter.record("a", at(0));
    expect(limiter.allows("a", at(0))).toBe(false);
    expect(limiter.allows("a", at(minute))).toBe(true);
  });

  it("forgets keys whose hits all left the window", () => {
    const limiter = new RateLimiter(5, minute, 3);
    limiter.take("a", at(0));
    limiter.take("b", at(0));
    limiter.take("c", at(0));
    expect(limiter.size).toBe(3);
    // A fourth key over the soft cap sweeps the expired ones first.
    limiter.take("d", at(2 * minute));
    expect(limiter.size).toBe(1);
  });
});
