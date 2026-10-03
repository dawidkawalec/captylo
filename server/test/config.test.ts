import { describe, expect, it } from "vitest";
import { loadConfig } from "../src/config.js";

const productionEnv = {
  NODE_ENV: "production",
  DATABASE_URL: "postgres://captylo@captylo-api-postgres/captylo",
  STRIPE_SECRET_KEY: "sk_test_fake",
  STRIPE_WEBHOOK_SECRET: "whsec_fake",
  STRIPE_PRICE_YEARLY: "price_fake_yearly",
  STRIPE_PRICE_MONTHLY: "price_fake_monthly",
  RESEND_API_KEY: "re_fake",
  OPENROUTER_API_KEY: "or_fake",
  STT_API_KEY: "stt_fake",
};

describe("loadConfig", () => {
  it("fills the defaults in development", () => {
    const config = loadConfig({ DATABASE_URL: "postgres://localhost/captylo" });
    expect(config).toEqual({
      port: 8080,
      databaseUrl: "postgres://localhost/captylo",
      publicSiteUrl: "https://captylo.com",
      stripeSecretKey: "",
      stripeWebhookSecret: "",
      stripePriceYearly: "",
      stripePriceMonthly: "",
      resendApiKey: "",
      mailFrom: "Captylo <konto@captylo.com>",
      openRouterKey: "",
      openRouterBaseUrl: "https://openrouter.ai/api/v1",
      proAiModel: "google/gemini-2.5-flash-lite",
      sttKey: "",
      sttBaseUrl: "https://api.elevenlabs.io/v1",
      proAudioHoursPerMonth: 20,
      proAiTokensPerMonth: 3_000_000,
      sessionDays: 180,
      nodeEnv: "development",
    });
  });

  it("reads every value from the environment", () => {
    const config = loadConfig({
      ...productionEnv,
      PORT: "9000",
      PUBLIC_SITE_URL: "https://captylo.stagingsite.pl/",
      MAIL_FROM: "Captylo <test@captylo.com>",
      OPENROUTER_BASE_URL: "http://127.0.0.1:9999/v1/",
      PRO_AI_MODEL: "some/model",
      STT_BASE_URL: "http://127.0.0.1:9998/v1",
      PRO_AUDIO_HOURS_PER_MONTH: "12.5",
      PRO_AI_TOKENS_PER_MONTH: "1000",
      SESSION_DAYS: "30",
    });
    expect(config.port).toBe(9000);
    expect(config.publicSiteUrl).toBe("https://captylo.stagingsite.pl");
    expect(config.openRouterBaseUrl).toBe("http://127.0.0.1:9999/v1");
    expect(config.proAiModel).toBe("some/model");
    expect(config.proAudioHoursPerMonth).toBe(12.5);
    expect(config.proAiTokensPerMonth).toBe(1000);
    expect(config.sessionDays).toBe(30);
    expect(config.nodeEnv).toBe("production");
    expect(config.stripePriceMonthly).toBe("price_fake_monthly");
  });

  it("treats blank values as unset", () => {
    const config = loadConfig({ DATABASE_URL: "postgres://localhost/captylo", PORT: "  ", PRO_AI_MODEL: "" });
    expect(config.port).toBe(8080);
    expect(config.proAiModel).toBe("google/gemini-2.5-flash-lite");
  });

  it("always requires DATABASE_URL", () => {
    expect(() => loadConfig({})).toThrow(/DATABASE_URL/);
    expect(() => loadConfig({ DATABASE_URL: "mysql://nope" })).toThrow(/DATABASE_URL/);
  });

  it("requires every secret in production and names the missing ones only", () => {
    const { STRIPE_WEBHOOK_SECRET: _w, STT_API_KEY: _s, ...partial } = productionEnv;
    let message = "";
    try {
      loadConfig(partial);
    } catch (error) {
      message = (error as Error).message;
    }
    expect(message).toContain("STRIPE_WEBHOOK_SECRET");
    expect(message).toContain("STT_API_KEY");
    expect(message).not.toContain("STRIPE_SECRET_KEY");
    expect(message).not.toContain("sk_test_fake");
    expect(message).not.toContain("captylo-api-postgres");
  });

  it("accepts a complete production environment", () => {
    expect(loadConfig(productionEnv).nodeEnv).toBe("production");
  });

  it("rejects malformed numbers, URLs and modes", () => {
    const base = { DATABASE_URL: "postgres://localhost/captylo" };
    expect(() => loadConfig({ ...base, PORT: "eighty" })).toThrow(/PORT/);
    expect(() => loadConfig({ ...base, PORT: "70000" })).toThrow(/PORT/);
    expect(() => loadConfig({ ...base, PRO_AUDIO_HOURS_PER_MONTH: "-1" })).toThrow(/PRO_AUDIO_HOURS_PER_MONTH/);
    expect(() => loadConfig({ ...base, PRO_AI_TOKENS_PER_MONTH: "1.5" })).toThrow(/PRO_AI_TOKENS_PER_MONTH/);
    expect(() => loadConfig({ ...base, SESSION_DAYS: "0" })).toThrow(/SESSION_DAYS/);
    expect(() => loadConfig({ ...base, PUBLIC_SITE_URL: "captylo.com" })).toThrow(/PUBLIC_SITE_URL/);
    expect(() => loadConfig({ ...base, NODE_ENV: "staging" })).toThrow(/NODE_ENV/);
  });
});
