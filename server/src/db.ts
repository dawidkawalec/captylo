import { readdir, readFile } from "node:fs/promises";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import pg from "pg";

/**
 * The one database interface routes see. Production wraps a `pg` pool, tests wrap pglite
 * (`test/helpers.ts`), so no route ever imports a driver.
 */
export interface Db {
  query<T = Record<string, unknown>>(text: string, params?: unknown[]): Promise<T[]>;
  one<T = Record<string, unknown>>(text: string, params?: unknown[]): Promise<T | undefined>;
  /** Runs a script of one or more statements without parameters (migrations). */
  exec(sql: string): Promise<void>;
  /** Runs `fn` in a transaction; a nested `tx` joins the outer one. */
  tx<T>(fn: (db: Db) => Promise<T>): Promise<T>;
}

/** `migrations/` next to `src/` and `dist/`, so the same path works in development and in the image. */
export const migrationsDir = fileURLToPath(new URL("../migrations/", import.meta.url));

/** Postgres `bigint` arrives as text from `pg`; counters fit a number, anything larger is a bug. */
export function parseInt8(text: string): number {
  const value = Number(text);
  if (!Number.isSafeInteger(value)) throw new RangeError("bigint value out of the safe integer range");
  return value;
}

const INT8_OID = 20;

export function createPool(databaseUrl: string): pg.Pool {
  return new pg.Pool({
    connectionString: databaseUrl,
    max: 10,
    idleTimeoutMillis: 30_000,
    types: {
      getTypeParser: ((oid: number, format?: "text" | "binary") =>
        oid === INT8_OID && format !== "binary" ? parseInt8 : pg.types.getTypeParser(oid, format)) as typeof pg.types.getTypeParser,
    },
  });
}

type Queryable = Pick<pg.Pool | pg.PoolClient, "query">;

export function dbFromPool(pool: pg.Pool): Db {
  return wrap(pool, async (fn) => {
    const client = await pool.connect();
    try {
      await client.query("begin");
      const result = await fn(wrap(client, (inner) => inner(wrapClient(client))));
      await client.query("commit");
      return result;
    } catch (error) {
      await client.query("rollback").catch(() => undefined);
      throw error;
    } finally {
      client.release();
    }
  });
}

function wrapClient(client: pg.PoolClient): Db {
  return wrap(client, (fn) => fn(wrapClient(client)));
}

function wrap(target: Queryable, tx: <T>(fn: (db: Db) => Promise<T>) => Promise<T>): Db {
  return {
    async query<T>(text: string, params?: unknown[]): Promise<T[]> {
      const result = await target.query(text, params);
      return result.rows as T[];
    },
    async one<T>(text: string, params?: unknown[]): Promise<T | undefined> {
      const result = await target.query(text, params);
      return result.rows[0] as T | undefined;
    },
    async exec(sql: string): Promise<void> {
      await target.query(sql);
    },
    tx,
  };
}

/** Arbitrary constant for `pg_advisory_xact_lock`, so two booting instances never migrate at once. */
const MIGRATION_LOCK = 4_242_001;

/**
 * Applies `dir/*.sql` in name order, each once, each in its own transaction, and records it in
 * `schema_migrations`. Returns the names applied by this call (empty when up to date).
 */
export async function migrate(db: Db, dir: string = migrationsDir): Promise<string[]> {
  await db.exec(
    "create table if not exists schema_migrations (name text primary key, applied_at timestamptz not null default now())",
  );
  const files = (await readdir(dir)).filter((name) => name.endsWith(".sql")).sort();
  const applied: string[] = [];
  for (const name of files) {
    const sql = await readFile(join(dir, name), "utf8");
    const didApply = await db.tx(async (t) => {
      await t.query("select pg_advisory_xact_lock($1)", [MIGRATION_LOCK]);
      const done = await t.one("select name from schema_migrations where name = $1", [name]);
      if (done) return false;
      await t.exec(sql);
      await t.query("insert into schema_migrations (name) values ($1)", [name]);
      return true;
    });
    if (didApply) applied.push(name);
  }
  return applied;
}
