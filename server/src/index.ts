import { serve } from "@hono/node-server";
import { buildApp } from "./app.js";
import { loadConfig } from "./config.js";
import { createPool, dbFromPool, migrate } from "./db.js";
import { createLogger } from "./lib/log.js";
import { createMailer } from "./lib/mail.js";
import { PURGE_INTERVAL_MS, purgeExpired } from "./lib/purge.js";
import { createStripe } from "./lib/stripe.js";

const log = createLogger();

async function main(): Promise<void> {
  const config = loadConfig();
  const pool = createPool(config.databaseUrl);
  pool.on("error", (err) => log.error({ error: err.name, code: (err as { code?: string }).code }, "idle client error"));
  const db = dbFromPool(pool);

  const applied = await migrate(db);
  log.info({ migrations: applied.length > 0 ? applied.join(",") : "none" }, "migrations applied");

  const purge = () =>
    purgeExpired(db, new Date())
      .then((deleted) => log.info(deleted, "purge done"))
      .catch((err: unknown) => log.error({ error: err instanceof Error ? err.name : "unknown" }, "purge failed"));
  await purge();
  const purgeTimer = setInterval(purge, PURGE_INTERVAL_MS);
  purgeTimer.unref();

  const mailer = createMailer(config);
  const stripe = createStripe(config);
  const app = buildApp({ config, db, mailer, stripe, fetchUpstream: fetch, now: () => new Date(), log });
  const server = serve({ fetch: app.fetch, port: config.port, hostname: "0.0.0.0" }, (info) => {
    log.info({ port: info.port, nodeEnv: config.nodeEnv }, "listening");
  });

  const shutdown = (signal: string) => {
    log.info({ signal }, "shutting down");
    clearInterval(purgeTimer);
    server.close(() => {
      pool.end().finally(() => process.exit(0));
    });
    setTimeout(() => process.exit(1), 10_000).unref();
  };
  process.on("SIGTERM", () => shutdown("SIGTERM"));
  process.on("SIGINT", () => shutdown("SIGINT"));
}

main().catch((err: unknown) => {
  // Config errors name variables only; any other boot error logs its type and code.
  const error = err instanceof Error ? err : new Error("unknown");
  const isConfig = error.message.startsWith("Invalid configuration:");
  log.error(
    { error: error.name, code: (error as { code?: string }).code, detail: isConfig ? error.message : undefined },
    "boot failed",
  );
  process.exit(1);
});
