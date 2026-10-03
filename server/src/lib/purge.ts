import type { Db } from "../db.js";
import { monthKey } from "./usage.js";

/** Login codes are deleted this long after they expired (the privacy policy promises a day). */
const CODE_GRACE_MS = 24 * 60 * 60_000;
/** Usage counters are kept for the current month and the 12 before it (the policy says 13 months). */
const USAGE_MONTHS_KEPT = 13;
/** How often the server runs the purge after the one at boot. */
export const PURGE_INTERVAL_MS = 6 * 60 * 60_000;

/** The oldest "YYYY-MM" kept in `usage_monthly`; every older month is deleted. */
export function usageCutoffMonth(now: Date): string {
  return monthKey(new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() - (USAGE_MONTHS_KEPT - 1), 1)));
}

/**
 * Deletes what the privacy policy says we do not keep: login codes a day after they expired and
 * usage counters older than 13 months. Runs at boot and every 6 hours, so nothing depends on the
 * next sign-in. Returns the deleted counts (logged as numbers only).
 */
export async function purgeExpired(db: Db, now: Date): Promise<{ codes: number; usageRows: number }> {
  const codes = await db.query("delete from login_codes where expires_at < $1 returning id", [
    new Date(now.getTime() - CODE_GRACE_MS),
  ]);
  const usageRows = await db.query("delete from usage_monthly where month < $1 returning month", [usageCutoffMonth(now)]);
  return { codes: codes.length, usageRows: usageRows.length };
}
