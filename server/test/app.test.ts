import { HTTPException } from "hono/http-exception";
import { beforeEach, describe, expect, it } from "vitest";
import { buildApp } from "../src/app.js";
import { testDeps, type TestDeps } from "./helpers.js";

let deps: TestDeps;

beforeEach(async () => {
  deps = await testDeps();
});

describe("GET /v1/health", () => {
  it("answers ok with a request id", async () => {
    const res = await buildApp(deps).request("/v1/health");
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ ok: true });
    expect(res.headers.get("X-Request-Id")).toMatch(/^[0-9a-f]{16}$/);
  });

  it("gives every request its own id", async () => {
    const app = buildApp(deps);
    const a = (await app.request("/v1/health")).headers.get("X-Request-Id");
    const b = (await app.request("/v1/health")).headers.get("X-Request-Id");
    expect(a).not.toBe(b);
  });

  it("ignores a request id sent by the client", async () => {
    const res = await buildApp(deps).request("/v1/health", { headers: { "X-Request-Id": "attacker-chosen" } });
    expect(res.headers.get("X-Request-Id")).toMatch(/^[0-9a-f]{16}$/);
  });

  it("logs the request with its id, path and status, without the query string", async () => {
    const res = await buildApp(deps).request("/v1/health?email=a@b.pl");
    const reqId = res.headers.get("X-Request-Id");
    const line = deps.log.lines.find((l) => l.fields.path === "/v1/health");
    expect(line?.level).toBe("info");
    expect(line?.fields).toMatchObject({ reqId, method: "GET", path: "/v1/health", status: 200 });
    expect(typeof line?.fields.ms).toBe("number");
    expect(JSON.stringify(deps.log.lines)).not.toContain("a@b.pl");
  });
});

describe("errors", () => {
  it("answers unknown routes with a JSON 404", async () => {
    const res = await buildApp(deps).request("/v1/nope", { method: "POST" });
    expect(res.status).toBe(404);
    expect(await res.json()).toEqual({ error: "not_found" });
    expect(res.headers.get("X-Request-Id")).toMatch(/^[0-9a-f]{16}$/);
  });

  it("keeps the status of a client error but never its message", async () => {
    const app = buildApp(deps);
    app.post("/v1/limited", () => {
      throw new HTTPException(413, { message: "body of anna@example.pl too large" });
    });
    const res = await app.request("/v1/limited", { method: "POST" });
    expect(res.status).toBe(413);
    expect(await res.json()).toEqual({ error: "too_large" });
  });

  it("answers a crash with a JSON 500 carrying the request id and no details", async () => {
    const app = buildApp(deps);
    app.get("/v1/boom", () => {
      throw new Error("duplicate key (email)=(anna@example.pl)");
    });
    const res = await app.request("/v1/boom");
    expect(res.status).toBe(500);
    const reqId = res.headers.get("X-Request-Id");
    const body = await res.text();
    expect(JSON.parse(body)).toEqual({ error: "internal", requestId: reqId });
    expect(body).not.toContain("anna@example.pl");
    expect(body).not.toContain("at ");
    const errorLine = deps.log.lines.find((l) => l.level === "error");
    expect(errorLine?.fields).toMatchObject({ reqId, error: "Error" });
    expect(JSON.stringify(deps.log.lines)).not.toContain("anna@example.pl");
  });
});
