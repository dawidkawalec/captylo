import { createHash, randomBytes, randomUUID } from "node:crypto";

/** 16 lowercase hex characters, the `X-Request-Id` of one request. */
export function requestId(): string {
  return randomBytes(8).toString("hex");
}

/** A random v4 uuid for primary keys. */
export function uuid(): string {
  return randomUUID();
}

/** 32 random bytes as base64url: 43 characters, the bearer token of one session. */
export function sessionToken(): string {
  return randomBytes(32).toString("base64url");
}

/** Lowercase hex sha256 of a UTF-8 string. */
export function sha256(text: string): string {
  return createHash("sha256").update(text, "utf8").digest("hex");
}

/**
 * A short, stable pseudonym of an e-mail address for logs: the first 16 hex characters of
 * its sha256. Lets two log lines be matched up without the address itself in the log.
 */
export function emailHash(email: string): string {
  return sha256(`log:${email.trim().toLowerCase()}`).slice(0, 16);
}

/** The same kind of log pseudonym for an account id, so relay lines of one account can be matched up. */
export function userHash(userId: string): string {
  return sha256(`log:user:${userId}`).slice(0, 16);
}
