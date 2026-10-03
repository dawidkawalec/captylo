import type { Db } from "../db.js";

/** One account's counters for one month. */
export interface Usage {
  audioSeconds: number;
  aiTokens: number;
}

/** "YYYY-MM" of `now` in UTC, the key of `usage_monthly`. */
export function monthKey(now: Date): string {
  return now.toISOString().slice(0, 7);
}

/** Midnight UTC on the first day of the month after `now`: when the counters start from zero. */
export function nextMonthStart(now: Date): Date {
  return new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() + 1, 1));
}

/** This month's counters of the account; zeros when it made no relay request this month. */
export async function usageFor(db: Db, userId: string, now: Date): Promise<Usage> {
  const row = await db.one<{ audio_seconds: unknown; ai_tokens: unknown }>(
    "select audio_seconds, ai_tokens from usage_monthly where user_id = $1 and month = $2",
    [userId, monthKey(now)],
  );
  // `bigint` arrives as a number from `pg` (see `parseInt8`) and may be a bigint or text elsewhere.
  return row ? { audioSeconds: Number(row.audio_seconds), aiTokens: Number(row.ai_tokens) } : { audioSeconds: 0, aiTokens: 0 };
}

/**
 * Adds to this month's counters in one upsert, so parallel requests never lose a count.
 * Deltas are rounded up to whole units; negative or non-finite ones count as zero.
 */
export async function addUsage(db: Db, userId: string, now: Date, delta: Partial<Usage>): Promise<void> {
  const audio = whole(delta.audioSeconds);
  const tokens = whole(delta.aiTokens);
  if (audio === 0 && tokens === 0) return;
  await db.query(
    `insert into usage_monthly as u (user_id, month, audio_seconds, ai_tokens) values ($1, $2, $3, $4)
     on conflict (user_id, month) do update set
       audio_seconds = u.audio_seconds + excluded.audio_seconds,
       ai_tokens = u.ai_tokens + excluded.ai_tokens`,
    [userId, monthKey(now), audio, tokens],
  );
}

/** Whether a request of `requestSeconds` would take the month's audio past `capSeconds`. */
export function overAudioCap(usage: Usage, capSeconds: number, requestSeconds: number): boolean {
  return usage.audioSeconds + requestSeconds > capSeconds;
}

/**
 * Whether the month's AI tokens reached `cap`. The size of the next request is known only
 * after the vendor answers, so the last request of a month may go a little over.
 */
export function overTokenCap(usage: Usage, cap: number): boolean {
  return usage.aiTokens >= cap;
}

function whole(value: number | undefined): number {
  return value !== undefined && Number.isFinite(value) && value > 0 ? Math.ceil(value) : 0;
}
