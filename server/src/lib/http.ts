import type { Context, MiddlewareHandler } from "hono";
import { bodyLimit } from "hono/body-limit";
import type { AppEnv } from "../app.js";

/** Caps a JSON request body (8 KB by default) and answers 413 `{ "error": "too_large" }` above it. */
export function smallBody(maxSize = 8 * 1024): MiddlewareHandler<AppEnv> {
  return bodyLimit({ maxSize, onError: (c) => c.json({ error: "too_large" }, 413) });
}

/** The JSON body when it is an object, otherwise undefined (missing, broken, an array, a string). */
export async function readJsonObject(c: Context<AppEnv>): Promise<Record<string, unknown> | undefined> {
  try {
    const body: unknown = await c.req.json();
    return body !== null && typeof body === "object" && !Array.isArray(body) ? (body as Record<string, unknown>) : undefined;
  } catch {
    return undefined;
  }
}

/** The client address Caddy puts first in `X-Forwarded-For`; used only as a limiter key, never logged. */
export function clientIp(c: Context<AppEnv>): string {
  const first = c.req.header("X-Forwarded-For")?.split(",")[0]?.trim();
  return first ? first : "unknown";
}
