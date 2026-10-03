import { describe, expect, it } from "vitest";
import { createMailer, LogMailer, loginCodeMessage, MailError, ResendMailer, type ResendLike } from "../src/lib/mail.js";
import { testConfig } from "./helpers.js";

function fakeResend(result: Awaited<ReturnType<ResendLike["emails"]["send"]>> | Error) {
  const calls: unknown[] = [];
  const client: ResendLike = {
    emails: {
      send: async (payload) => {
        calls.push(payload);
        if (result instanceof Error) throw result;
        return result;
      },
    },
  };
  return { client, calls };
}

describe("loginCodeMessage", () => {
  it("puts the code in the subject and in both languages, Polish first", () => {
    const message = loginCodeMessage("042917");
    expect(message.subject).toBe("Twój kod do Captylo: 042917");
    expect(message.text).toBe(
      [
        "Twój kod do Captylo: 042917",
        "Wpisz go w aplikacji w ciągu 10 minut. Jeśli to nie Ty, zignoruj tę wiadomość.",
        "",
        "Your Captylo code: 042917",
        "Enter it in the app within 10 minutes. If this was not you, ignore this message.",
      ].join("\n"),
    );
    expect(message.text.indexOf("Twój")).toBeLessThan(message.text.indexOf("Your"));
  });

  it("renders a minimal HTML body with the code in a 28 px monospace block, no images or links", () => {
    const { html } = loginCodeMessage("042917");
    expect(html).toContain("042917");
    expect(html).toMatch(/font-size:\s*28px/);
    expect(html).toContain("monospace");
    expect(html).toContain('lang="pl"');
    expect(html).not.toMatch(/<img|<a\s|https?:\/\//i);
  });
});

describe("ResendMailer", () => {
  it("sends text and HTML from the configured sender", async () => {
    const { client, calls } = fakeResend({ data: { id: "email_1" }, error: null, headers: null });
    await new ResendMailer("re_fake", "Captylo <konto@captylo.com>", client).send("a@b.pl", "S", "T", "<p>H</p>");
    expect(calls).toEqual([{ from: "Captylo <konto@captylo.com>", to: "a@b.pl", subject: "S", text: "T", html: "<p>H</p>" }]);
  });

  it("turns an error response into a MailError without the provider's message", async () => {
    const { client } = fakeResend({
      data: null,
      error: { name: "validation_error", message: "a@b.pl is not allowed", statusCode: 422 },
      headers: null,
    });
    const error = await new ResendMailer("re_fake", "x@y.pl", client).send("a@b.pl", "S", "T", "H").catch((e: unknown) => e);
    expect(error).toBeInstanceOf(MailError);
    expect((error as MailError).message).toBe("validation_error");
    expect((error as MailError).message).not.toContain("a@b.pl");
  });

  it("turns a thrown error (network) into a MailError", async () => {
    const { client } = fakeResend(new Error("connect ECONNREFUSED for a@b.pl"));
    const error = await new ResendMailer("re_fake", "x@y.pl", client).send("a@b.pl", "S", "T", "H").catch((e: unknown) => e);
    expect(error).toBeInstanceOf(MailError);
    expect((error as MailError).message).not.toContain("a@b.pl");
  });
});

describe("LogMailer", () => {
  it("records messages in memory", async () => {
    const mailer = new LogMailer("development");
    await mailer.send("a@b.pl", "S", "T", "H");
    expect(mailer.sent).toEqual([{ to: "a@b.pl", subject: "S", text: "T", html: "H" }]);
  });

  it("refuses to exist in production", () => {
    expect(() => new LogMailer("production")).toThrow();
  });
});

describe("createMailer", () => {
  it("uses Resend when a key is configured and the log mailer otherwise", () => {
    expect(createMailer(testConfig({ RESEND_API_KEY: "re_fake_for_tests" }))).toBeInstanceOf(ResendMailer);
    expect(createMailer(testConfig())).toBeInstanceOf(LogMailer);
  });
});
