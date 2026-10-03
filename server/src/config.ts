export type NodeEnv = "production" | "development" | "test";

export interface Config {
  /** PORT, default 8080 */
  port: number;
  /** DATABASE_URL (postgres://...), always required */
  databaseUrl: string;
  /** PUBLIC_SITE_URL, default https://captylo.com, no trailing slash */
  publicSiteUrl: string;
  /** STRIPE_SECRET_KEY */
  stripeSecretKey: string;
  /** STRIPE_WEBHOOK_SECRET */
  stripeWebhookSecret: string;
  /** STRIPE_PRICE_YEARLY (price_...) */
  stripePriceYearly: string;
  /** STRIPE_PRICE_MONTHLY (price_...) */
  stripePriceMonthly: string;
  /** RESEND_API_KEY ("" = log mailer, development only) */
  resendApiKey: string;
  /** MAIL_FROM, default "Captylo <konto@captylo.com>" */
  mailFrom: string;
  /** OPENROUTER_API_KEY */
  openRouterKey: string;
  /** OPENROUTER_BASE_URL, default https://openrouter.ai/api/v1 */
  openRouterBaseUrl: string;
  /** PRO_AI_MODEL, default google/gemini-2.5-flash-lite */
  proAiModel: string;
  /** STT_API_KEY (cloud speech to text) */
  sttKey: string;
  /** STT_BASE_URL, default https://api.elevenlabs.io/v1 */
  sttBaseUrl: string;
  /** PRO_AUDIO_HOURS_PER_MONTH, default 20 */
  proAudioHoursPerMonth: number;
  /** PRO_AI_TOKENS_PER_MONTH, default 3,000,000 */
  proAiTokensPerMonth: number;
  /** SESSION_DAYS, default 180: a session unused this long expires */
  sessionDays: number;
  /** NODE_ENV, default development */
  nodeEnv: NodeEnv;
}

/** Secrets the service cannot run without in production; blank is allowed in development and tests. */
const productionSecrets = [
  "STRIPE_SECRET_KEY",
  "STRIPE_WEBHOOK_SECRET",
  "STRIPE_PRICE_YEARLY",
  "STRIPE_PRICE_MONTHLY",
  "RESEND_API_KEY",
  "OPENROUTER_API_KEY",
  "STT_API_KEY",
] as const;

type Env = Record<string, string | undefined>;

/**
 * Reads the configuration from the environment and fails fast with every problem at once.
 * Error messages name the variables, never their values.
 */
export function loadConfig(env: Env = process.env): Config {
  const problems: string[] = [];
  const read = (name: string, fallback = ""): string => {
    const value = env[name]?.trim();
    return value ? value : fallback;
  };

  const nodeEnvRaw = read("NODE_ENV", "development");
  let nodeEnv: NodeEnv = "development";
  if (nodeEnvRaw === "production" || nodeEnvRaw === "development" || nodeEnvRaw === "test") {
    nodeEnv = nodeEnvRaw;
  } else {
    problems.push("NODE_ENV must be production, development or test");
  }

  const number = (name: string, fallback: number, rule: { integer?: boolean; min: number; max?: number }): number => {
    const raw = read(name);
    if (!raw) return fallback;
    const value = Number(raw);
    const ok =
      Number.isFinite(value) &&
      (!rule.integer || Number.isInteger(value)) &&
      value >= rule.min &&
      (rule.max === undefined || value <= rule.max);
    if (!ok) {
      problems.push(`${name} must be ${rule.integer ? "an integer" : "a number"} >= ${rule.min}${rule.max ? ` and <= ${rule.max}` : ""}`);
      return fallback;
    }
    return value;
  };

  const url = (name: string, fallback: string, protocols: string[]): string => {
    const raw = read(name, fallback);
    if (!raw) return "";
    try {
      const parsed = new URL(raw);
      if (!protocols.includes(parsed.protocol)) throw new Error("protocol");
    } catch {
      problems.push(`${name} must be a ${protocols.join(" or ")} URL`);
    }
    return raw.replace(/\/+$/, "");
  };

  const databaseUrl = url("DATABASE_URL", "", ["postgres:", "postgresql:"]);
  if (!databaseUrl) problems.push("DATABASE_URL is required");

  if (nodeEnv === "production") {
    const missing = productionSecrets.filter((name) => !read(name));
    if (missing.length > 0) problems.push(`missing in production: ${missing.join(", ")}`);
  }

  const config: Config = {
    port: number("PORT", 8080, { integer: true, min: 1, max: 65535 }),
    databaseUrl,
    publicSiteUrl: url("PUBLIC_SITE_URL", "https://captylo.com", ["https:", "http:"]),
    stripeSecretKey: read("STRIPE_SECRET_KEY"),
    stripeWebhookSecret: read("STRIPE_WEBHOOK_SECRET"),
    stripePriceYearly: read("STRIPE_PRICE_YEARLY"),
    stripePriceMonthly: read("STRIPE_PRICE_MONTHLY"),
    resendApiKey: read("RESEND_API_KEY"),
    mailFrom: read("MAIL_FROM", "Captylo <konto@captylo.com>"),
    openRouterKey: read("OPENROUTER_API_KEY"),
    openRouterBaseUrl: url("OPENROUTER_BASE_URL", "https://openrouter.ai/api/v1", ["https:", "http:"]),
    proAiModel: read("PRO_AI_MODEL", "google/gemini-2.5-flash-lite"),
    sttKey: read("STT_API_KEY"),
    sttBaseUrl: url("STT_BASE_URL", "https://api.elevenlabs.io/v1", ["https:", "http:"]),
    proAudioHoursPerMonth: number("PRO_AUDIO_HOURS_PER_MONTH", 20, { min: 0 }),
    proAiTokensPerMonth: number("PRO_AI_TOKENS_PER_MONTH", 3_000_000, { integer: true, min: 0 }),
    sessionDays: number("SESSION_DAYS", 180, { integer: true, min: 1 }),
    nodeEnv,
  };

  if (problems.length > 0) throw new Error(`Invalid configuration: ${problems.join("; ")}`);
  return config;
}
