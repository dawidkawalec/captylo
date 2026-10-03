import type { Db } from "../db.js";
import { uuid } from "./ids.js";
import type { SessionUser } from "./sessions.js";

/** The user with this address, created when missing (citext: the case of the address never matters). */
export async function findOrCreateUser(db: Db, email: string, now: Date): Promise<SessionUser> {
  await db.query("insert into users (id, email, created_at) values ($1, $2, $3) on conflict (email) do nothing", [uuid(), email, now]);
  const user = await db.one<SessionUser>("select id, email from users where email = $1", [email]);
  if (!user) throw new Error("user row missing after upsert");
  return user;
}
