import Stripe from "stripe";
import type { Config } from "../config.js";

/**
 * The API version the server speaks. stripe-node 22.6 types only this version, so the
 * webhook endpoint in the Dashboard must be created with the same version.
 */
export const STRIPE_API_VERSION: Stripe.LatestApiVersion = "2026-08-26.dahlia";

/** The five Stripe calls the server makes, so tests pass a fake. A real `Stripe` client fits it. */
export interface StripeLike {
  customers: {
    create(params: Stripe.CustomerCreateParams): Promise<{ id: string }>;
  };
  checkout: {
    sessions: {
      create(params: Stripe.Checkout.SessionCreateParams): Promise<{ id: string; url: string | null }>;
    };
  };
  billingPortal: {
    sessions: {
      create(params: Stripe.BillingPortal.SessionCreateParams): Promise<{ url: string }>;
    };
  };
  webhooks: {
    /** Verifies `Stripe-Signature` over the raw body and parses the event; throws on a bad signature. */
    constructEvent(payload: string, header: string, secret: string): Stripe.Event;
  };
  subscriptions: {
    retrieve(id: string): Promise<Stripe.Subscription>;
  };
}

/** Thrown by every call when `STRIPE_SECRET_KEY` is blank (development without Stripe). */
export class StripeNotConfiguredError extends Error {
  override name = "StripeNotConfiguredError";
}

/** The real client, or one that refuses every call when the key is blank (refused at boot in production). */
export function createStripe(config: Pick<Config, "stripeSecretKey">): StripeLike {
  if (!config.stripeSecretKey) return unconfiguredStripe();
  return new Stripe(config.stripeSecretKey, {
    apiVersion: STRIPE_API_VERSION,
    maxNetworkRetries: 2,
    timeout: 20_000,
    appInfo: { name: "captylo-api", url: "https://captylo.com" },
  });
}

function unconfiguredStripe(): StripeLike {
  const refuse = (): never => {
    throw new StripeNotConfiguredError("STRIPE_SECRET_KEY is not set");
  };
  return {
    customers: { create: async () => refuse() },
    checkout: { sessions: { create: async () => refuse() } },
    billingPortal: { sessions: { create: async () => refuse() } },
    webhooks: { constructEvent: () => refuse() },
    subscriptions: { retrieve: async () => refuse() },
  };
}

/** The id of an expandable Stripe field (`"cus_..."` or `{ id: "cus_..." }`), undefined when empty. */
export function stripeId(field: string | { id: string } | null | undefined): string | undefined {
  if (!field) return undefined;
  return typeof field === "string" ? field : field.id;
}

/** What a failed Stripe call may log: its class and Stripe's type and code, never the message (it can quote an address). */
export function stripeErrorFields(error: unknown): { error: string; type?: string; code?: string } {
  if (!(error instanceof Error)) return { error: "unknown" };
  const { type, code } = error as { type?: unknown; code?: unknown };
  return {
    error: error.name,
    ...(typeof type === "string" ? { type } : {}),
    ...(typeof code === "string" ? { code } : {}),
  };
}
