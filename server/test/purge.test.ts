import { beforeEach, describe, expect, it } from "vitest";
import type { Db } from "../src/db.js";
import { uuid } from "../src/lib/ids.js";
import { purgeExpired, usageCutoffMonth } from "../src/lib/purge.js";
import { testDb } from "./helpers.js";

describe("usageCutoffMonth", () => {
  it("keeps the current month and the 12 before it", () => {
    expect(usageCutoffMonth(new Date("2026-10-03T12:00:00Z"))).toBe("2025-10");
    expect(usageCutoffMonth(new Date("2027-01-01T00:30:00Z"))).toBe("2026-01");
  });
});

describe("purgeExpired", () => {
  let db: Db;
  const now = new Date("2026-10-03T12:00:00Z");

  beforeEach(async () => {
    ({ db } = await testDb());
  });

  async function addCode(expiresAt: string): Promise<void> {
    await db.query("insert into login_codes (id, email, code_hash, expires_at) values ($1, $2, $3, $4)", [
      uuid(),
      "a@b.pl",
      "hash",
      new Date(expiresAt),
    ]);
  }

  it("deletes login codes a day after they expired and keeps the rest", async () => {
    await addCode("2026-10-01T11:00:00Z"); // expired 2 days ago
    await addCode("2026-10-02T13:00:00Z"); // expired 23 h ago
    await addCode("2026-10-03T12:05:00Z"); // still valid
    const result = await purgeExpired(db, now);
    expect(result.codes).toBe(1);
    const left = await db.query("select id from login_codes");
    expect(left).toHaveLength(2);
  });

  it("deletes usage counters older than 13 months", async () => {
    const user = uuid();
    await db.query("insert into users (id, email) values ($1, $2)", [user, "a@b.pl"]);
    for (const month of ["2025-09", "2025-10", "2026-10"]) {
      await db.query("insert into usage_monthly (user_id, month, audio_seconds, ai_tokens) values ($1, $2, 1, 1)", [user, month]);
    }
    const result = await purgeExpired(db, now);
    expect(result.usageRows).toBe(1);
    const months = (await db.query<{ month: string }>("select month from usage_monthly order by month")).map((r) => r.month);
    expect(months).toEqual(["2025-10", "2026-10"]);
  });

  it("does nothing on an empty database", async () => {
    expect(await purgeExpired(db, now)).toEqual({ codes: 0, usageRows: 0 });
  });
});
