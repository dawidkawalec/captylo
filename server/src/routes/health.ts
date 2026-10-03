import { Hono } from "hono";

/** `GET /v1/health`: liveness for Docker, Caddy and the uptime monitor. */
export function healthRoutes(): Hono {
  const routes = new Hono();
  routes.get("/health", (c) => c.json({ ok: true }));
  return routes;
}
