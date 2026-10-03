import type { Db } from "../db.js";
import { sessionToken, sha256, uuid } from "./ids.js";

export interface SessionUser {
  id: string;
  email: string;
}

export interface Session {
  id: string;
  user: SessionUser;
}

/** `last_seen_at` is written at most this often, so every request does not write. */
const TOUCH_EVERY_MS = 60 * 60_000;
const DAY_MS = 24 * 60 * 60_000;

/** The shape of a token we issue: 32 bytes as base64url. Anything else is refused without a query. */
export function looksLikeToken(token: string): boolean {
  return /^[A-Za-z0-9_-]{43}$/.test(token);
}

/** Device names come from the app ("MacBook Pro"); control characters are dropped, 100 characters kept. */
export function cleanDevice(raw: unknown): string {
  if (typeof raw !== "string") return "";
  return raw.replace(/[\u0000-\u001f\u007f]/g, "").trim().slice(0, 100);
}

/** Opens a session for `userId` and returns its bearer token; only the token's sha256 is stored. */
export async function issueSession(db: Db, userId: string, device: string, now: Date): Promise<string> {
  const token = sessionToken();
  await db.query(
    "insert into sessions (id, user_id, token_hash, device, created_at, last_seen_at) values ($1, $2, $3, $4, $5, $5)",
    [uuid(), userId, sha256(token), device, now],
  );
  return token;
}

/**
 * The live session for a bearer token: not revoked and used within the last `sessionDays`.
 * Bumps `last_seen_at` when it is an hour old or more.
 */
export async function lookupSession(db: Db, token: string, now: Date, sessionDays: number): Promise<Session | undefined> {
  if (!looksLikeToken(token)) return undefined;
  const row = await db.one<{ id: string; last_seen_at: Date; user_id: string; email: string }>(
    `select s.id, s.last_seen_at, u.id as user_id, u.email
       from sessions s join users u on u.id = s.user_id
      where s.token_hash = $1 and s.revoked_at is null and s.last_seen_at > $2`,
    [sha256(token), new Date(now.getTime() - sessionDays * DAY_MS)],
  );
  if (!row) return undefined;
  if (now.getTime() - new Date(row.last_seen_at).getTime() >= TOUCH_EVERY_MS) {
    await db.query("update sessions set last_seen_at = $2 where id = $1", [row.id, now]);
  }
  return { id: row.id, user: { id: row.user_id, email: row.email } };
}

export async function revokeSession(db: Db, sessionId: string, now: Date): Promise<void> {
  await db.query("update sessions set revoked_at = $2 where id = $1 and revoked_at is null", [sessionId, now]);
}
