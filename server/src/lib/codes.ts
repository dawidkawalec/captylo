import { randomInt, timingSafeEqual } from "node:crypto";
import type { Db } from "../db.js";
import { sha256, uuid } from "./ids.js";

/** A code is valid this long after it was issued. */
export const CODE_TTL_MS = 10 * 60_000;
/** Attempts per code, right or wrong; the code is spent when they run out. */
export const MAX_ATTEMPTS = 5;
/** Expired codes are deleted this long after they expire (the table keeps no old addresses). */
const PURGE_AFTER_MS = 24 * 60 * 60_000;

/** Trimmed and lowercased; the column is citext as well, so lookups never depend on case. */
export function normalizeEmail(raw: string): string {
  return raw.trim().toLowerCase();
}

/** A syntactic check only (something@domain.tld, no spaces, at most 254 characters). */
export function isEmail(email: string): boolean {
  return email.length <= 254 && /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email);
}

/** Six digits, zero-padded, from a CSPRNG. */
export function newCode(): string {
  return String(randomInt(0, 1_000_000)).padStart(6, "0");
}

export function codeHash(email: string, code: string): string {
  return sha256(`${email.toLowerCase()}:${code}`);
}

/** Compared even when no code exists, so a missing code costs the same time as a wrong one. */
const NO_CODE_HASH = "0".repeat(64);

/**
 * Issues a new code for `email` and returns it (the caller mails it; only its hash is
 * stored). Every earlier unconsumed code for the address is spent, so only the newest works.
 */
export async function issueCode(db: Db, email: string, now: Date): Promise<string> {
  const code = newCode();
  await db.tx(async (t) => {
    await t.query("delete from login_codes where expires_at < $1", [new Date(now.getTime() - PURGE_AFTER_MS)]);
    await t.query("update login_codes set consumed_at = $2 where email = $1 and consumed_at is null", [email, now]);
    await t.query("insert into login_codes (id, email, code_hash, expires_at) values ($1, $2, $3, $4)", [
      uuid(),
      email,
      codeHash(email, code),
      new Date(now.getTime() + CODE_TTL_MS),
    ]);
  });
  return code;
}

/**
 * Checks `code` against the newest unconsumed, unexpired code for `email`. Every call uses
 * one attempt; the right code consumes it, the fifth attempt spends it either way. Returns
 * only whether it matched, never why not (no code, expired, wrong, out of attempts).
 */
export async function verifyCode(db: Db, email: string, code: string, now: Date): Promise<boolean> {
  return db.tx(async (t) => {
    const row = await t.one<{ id: string; code_hash: string; attempts: number }>(
      `select id, code_hash, attempts from login_codes
        where email = $1 and consumed_at is null and expires_at > $2
        order by expires_at desc limit 1
        for update`,
      [email, now],
    );
    const matches = timingSafeEqual(Buffer.from(row?.code_hash ?? NO_CODE_HASH, "hex"), Buffer.from(codeHash(email, code), "hex"));
    if (!row) return false;
    const attempts = row.attempts + 1;
    const ok = matches && attempts <= MAX_ATTEMPTS;
    const spent = ok || attempts >= MAX_ATTEMPTS;
    await t.query("update login_codes set attempts = $2, consumed_at = $3 where id = $1", [row.id, attempts, spent ? now : null]);
    return ok;
  });
}
