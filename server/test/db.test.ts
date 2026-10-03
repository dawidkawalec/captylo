import { copyFile, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { createPool, migrate, migrationsDir, parseInt8 } from "../src/db.js";
import { emptyDb, testDb } from "./helpers.js";

const tables = ["login_codes", "schema_migrations", "sessions", "stripe_events", "subscriptions", "usage_monthly", "users"];
const migrations = ["001_init.sql", "002_subscription_period_start.sql"];

describe("migrate", () => {
  it("creates the schema on an empty database and records the migration", async () => {
    const { db } = emptyDb();
    const applied = await migrate(db);
    expect(applied).toEqual(migrations);
    const rows = await db.query<{ table_name: string }>(
      "select table_name from information_schema.tables where table_schema = 'public' order by table_name",
    );
    expect(rows.map((r) => r.table_name)).toEqual(tables);
    const recorded = await db.query<{ name: string }>("select name from schema_migrations");
    expect(recorded.map((r) => r.name)).toEqual(migrations);
  });

  it("is idempotent: a second run applies nothing", async () => {
    const { db } = await testDb();
    expect(await migrate(db)).toEqual([]);
    const recorded = await db.query("select name from schema_migrations");
    expect(recorded).toHaveLength(migrations.length);
  });

  it("keeps e-mail addresses unique regardless of case", async () => {
    const { db } = await testDb();
    await db.query("insert into users (id, email) values (gen_random_uuid(), $1)", ["Anna@Example.PL"]);
    await expect(
      db.query("insert into users (id, email) values (gen_random_uuid(), $1)", ["anna@example.pl"]),
    ).rejects.toThrow();
    const found = await db.one<{ email: string }>("select email from users where email = $1", ["ANNA@EXAMPLE.PL"]);
    expect(found?.email).toBe("Anna@Example.PL");
  });

  it("returns bigint counters as numbers", async () => {
    const { db } = await testDb();
    const user = await db.one<{ id: string }>(
      "insert into users (id, email) values (gen_random_uuid(), 'a@b.pl') returning id",
    );
    await db.query("insert into usage_monthly (user_id, month, audio_seconds, ai_tokens) values ($1, '2026-10', 72000, 3000000)", [
      user?.id,
    ]);
    const usage = await db.one<{ audio_seconds: number; ai_tokens: number }>(
      "select audio_seconds, ai_tokens from usage_monthly",
    );
    expect(usage).toEqual({ audio_seconds: 72000, ai_tokens: 3000000 });
  });

  describe("with a custom directory", () => {
    let dir = "";
    afterEach(async () => {
      if (dir) await rm(dir, { recursive: true, force: true });
    });

    it("applies files in name order, once each, and only new ones later", async () => {
      dir = await mkdtemp(join(tmpdir(), "captylo-migrations-"));
      await writeFile(join(dir, "002_second.sql"), "insert into steps (name) values ('second');");
      await writeFile(join(dir, "001_first.sql"), "create table steps (n serial primary key, name text not null);");
      await writeFile(join(dir, "README.txt"), "not a migration");
      const { db } = emptyDb();
      expect(await migrate(db, dir)).toEqual(["001_first.sql", "002_second.sql"]);
      await writeFile(join(dir, "003_third.sql"), "insert into steps (name) values ('third');");
      expect(await migrate(db, dir)).toEqual(["003_third.sql"]);
      const steps = await db.query<{ name: string }>("select name from steps order by n");
      expect(steps.map((s) => s.name)).toEqual(["second", "third"]);
    });

    it("rolls back a failing migration and does not record it", async () => {
      dir = await mkdtemp(join(tmpdir(), "captylo-migrations-"));
      await writeFile(join(dir, "001_ok.sql"), "create table ok (id int);");
      await writeFile(join(dir, "002_broken.sql"), "create table half (id int); select * from missing_table;");
      const { db } = emptyDb();
      await expect(migrate(db, dir)).rejects.toThrow();
      const recorded = await db.query<{ name: string }>("select name from schema_migrations");
      expect(recorded.map((r) => r.name)).toEqual(["001_ok.sql"]);
      const half = await db.one("select to_regclass('public.half') as t");
      expect(half).toEqual({ t: null });
    });

    it("002 fills the period start of existing subscriptions one plan interval before the end", async () => {
      dir = await mkdtemp(join(tmpdir(), "captylo-migrations-"));
      await copyFile(join(migrationsDir, "001_init.sql"), join(dir, "001_init.sql"));
      const { db } = emptyDb();
      await migrate(db, dir);
      for (const [email, sub, plan] of [["a@b.pl", "sub_y", "yearly"], ["c@d.pl", "sub_m", "monthly"]]) {
        await db.query(
          `with u as (insert into users (id, email) values (gen_random_uuid(), $1) returning id)
           insert into subscriptions (user_id, stripe_subscription_id, status, plan, current_period_end, event_created)
           select id, $2, 'active', $3, '2027-03-31T10:00:00Z', 1 from u`,
          [email, sub, plan],
        );
      }
      await copyFile(join(migrationsDir, "002_subscription_period_start.sql"), join(dir, "002_subscription_period_start.sql"));
      expect(await migrate(db, dir)).toEqual(["002_subscription_period_start.sql"]);
      const rows = await db.query<{ stripe_subscription_id: string; start: string }>(
        `select stripe_subscription_id, to_char(current_period_start at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI') as start
           from subscriptions order by stripe_subscription_id`,
      );
      expect(rows).toEqual([
        { stripe_subscription_id: "sub_m", start: "2027-02-28T10:00" },
        { stripe_subscription_id: "sub_y", start: "2026-03-31T10:00" },
      ]);
      const column = await db.one<{ is_nullable: string }>(
        "select is_nullable from information_schema.columns where table_name = 'subscriptions' and column_name = 'current_period_start'",
      );
      expect(column?.is_nullable).toBe("NO");
    });
  });
});

describe("Db", () => {
  it("one returns undefined when no row matches", async () => {
    const { db } = await testDb();
    expect(await db.one("select id from users where email = $1", ["nobody@example.com"])).toBeUndefined();
  });

  it("tx commits on success and rolls back on a throw", async () => {
    const { db } = await testDb();
    await db.tx(async (t) => {
      await t.query("insert into stripe_events (id) values ('evt_ok')");
    });
    await expect(
      db.tx(async (t) => {
        await t.query("insert into stripe_events (id) values ('evt_rolled_back')");
        throw new Error("boom");
      }),
    ).rejects.toThrow("boom");
    const ids = await db.query<{ id: string }>("select id from stripe_events order by id");
    expect(ids.map((r) => r.id)).toEqual(["evt_ok"]);
  });
});

describe("createPool", () => {
  it("parses bigint as a number like pglite does, and leaves other types alone", async () => {
    const pool = createPool("postgres://nobody@127.0.0.1:1/none");
    const types = (pool as unknown as { options: { types: { getTypeParser: (oid: number, format?: string) => (v: string) => unknown } } })
      .options.types;
    expect(types.getTypeParser(20, "text")("72000")).toBe(72000);
    expect(types.getTypeParser(23, "text")("7")).toBe(7);
    expect(types.getTypeParser(25, "text")("abc")).toBe("abc");
    await pool.end();
  });
});

describe("parseInt8", () => {
  it("parses Postgres bigint text into a number", () => {
    expect(parseInt8("0")).toBe(0);
    expect(parseInt8("72000")).toBe(72000);
    expect(parseInt8("-5")).toBe(-5);
  });

  it("refuses values a number cannot hold exactly", () => {
    expect(() => parseInt8("9007199254740993")).toThrow();
  });
});
