import { Resend } from "resend";
import type { Config, NodeEnv } from "../config.js";

export interface Mailer {
  send(to: string, subject: string, text: string, html: string): Promise<void>;
}

/** A failed send. The message is the provider's error name only, never its text (it can quote the address). */
export class MailError extends Error {
  override name = "MailError";
}

/** The one call we make on the Resend SDK, so tests pass a fake. */
export interface ResendLike {
  emails: {
    send(payload: { from: string; to: string; subject: string; text: string; html: string }): Promise<{
      data: unknown;
      error: { name: string; message: string; statusCode: number | null } | null;
      headers: Record<string, string> | null;
    }>;
  };
}

const SEND_TIMEOUT_MS = 10_000;

/** Sends through Resend with `from` = `MAIL_FROM`. */
export class ResendMailer implements Mailer {
  private readonly client: ResendLike;

  constructor(
    apiKey: string,
    private readonly from: string,
    client?: ResendLike,
  ) {
    this.client = client ?? (new Resend(apiKey) as unknown as ResendLike);
  }

  async send(to: string, subject: string, text: string, html: string): Promise<void> {
    let timer: NodeJS.Timeout | undefined;
    const timeout = new Promise<never>((_, reject) => {
      timer = setTimeout(() => reject(new MailError("timeout")), SEND_TIMEOUT_MS);
      timer.unref();
    });
    try {
      const result = await Promise.race([this.client.emails.send({ from: this.from, to, subject, text, html }), timeout]);
      if (result.error) throw new MailError(result.error.name || "send_failed");
    } catch (error) {
      if (error instanceof MailError) throw error;
      throw new MailError(error instanceof Error ? error.name : "send_failed");
    } finally {
      clearTimeout(timer);
    }
  }
}

export interface RecordedMail {
  to: string;
  subject: string;
  text: string;
  html: string;
}

/**
 * Development and tests: keeps every message in `sent` and sends nothing. It never writes
 * a message to the log (the codes would end up there), and it refuses to run in production.
 */
export class LogMailer implements Mailer {
  readonly sent: RecordedMail[] = [];

  constructor(nodeEnv: NodeEnv) {
    if (nodeEnv === "production") throw new Error("LogMailer is not allowed in production");
  }

  async send(to: string, subject: string, text: string, html: string): Promise<void> {
    this.sent.push({ to, subject, text, html });
  }
}

/** Resend when `RESEND_API_KEY` is set, otherwise the in-memory mailer (refused in production). */
export function createMailer(config: Config): Mailer {
  return config.resendApiKey ? new ResendMailer(config.resendApiKey, config.mailFrom) : new LogMailer(config.nodeEnv);
}

/** The login-code e-mail: Polish first, English second, no images, no links, no tracking. */
export function loginCodeMessage(code: string): { subject: string; text: string; html: string } {
  const subject = `Twój kod do Captylo: ${code}`;
  const text = [
    `Twój kod do Captylo: ${code}`,
    "Wpisz go w aplikacji w ciągu 10 minut. Jeśli to nie Ty, zignoruj tę wiadomość.",
    "",
    `Your Captylo code: ${code}`,
    "Enter it in the app within 10 minutes. If this was not you, ignore this message.",
  ].join("\n");
  const font = "-apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif";
  const codeBlock = (lang: string) =>
    `<div lang="${lang}" style="font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; font-size: 28px; letter-spacing: 6px; font-weight: 600; padding: 12px 16px; margin: 8px 0 12px; background: #f2f4f7; border-radius: 8px; display: inline-block;">${code}</div>`;
  const html = `<!doctype html>
<html lang="pl">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>${subject}</title></head>
<body style="margin: 0; padding: 24px; font-family: ${font}; font-size: 15px; line-height: 1.5; color: #1d2433; background: #ffffff;">
<p style="margin: 0;">Twój kod do Captylo:</p>
${codeBlock("pl")}
<p style="margin: 0 0 24px;">Wpisz go w aplikacji w ciągu 10 minut. Jeśli to nie Ty, zignoruj tę wiadomość.</p>
<p lang="en" style="margin: 0;">Your Captylo code:</p>
${codeBlock("en")}
<p lang="en" style="margin: 0;">Enter it in the app within 10 minutes. If this was not you, ignore this message.</p>
</body>
</html>`;
  return { subject, text, html };
}
