# Pro backend (accounts, Pro, relay)

Status: built in M4 (code in `server/`, app side in `Captylo/Account/`); production bring-up (Stripe products, mail domain, DNS, the VPS stack) is done by the owner step by step. The operational detail of every endpoint, the Stripe events and the env variables lives in [server/README.md](../server/README.md); this page is the overview and the rules both sides keep.

## Why a server

Free users paste their own keys (Settings, Modele) and talk to the providers directly. Pro users get cloud transcription and AI with no setup, so those requests go out with **our** keys. A key shipped inside the app can be extracted from the binary (and this repo is public), so Pro traffic goes through a small relay that holds the keys server side and checks the subscription on every request.

## Architecture

One HTTP service, `api.captylo.com`: TypeScript on Node 22, Hono 4, Postgres 17, in `server/` of this repo (GPLv3). It runs on our VPS as the compose stack `captylo-api` (two containers, `captylo-api` and `captylo-api-postgres`) behind the shared Caddy, with no published ports. Secrets live only in `.env` on the VPS; the repo has `server/.env.example`.

```
Captylo.app ──(own key)──────────────────────────────> vendor (STT / AI)
     │
     └─(Pro session token)─> api.captylo.com ─(our key)─> vendor (STT / AI)
                                   │  users, sessions, codes, subscriptions, monthly usage (Postgres)
Stripe Checkout / Portal ─(webhook)┘
Resend <─(login codes)─────────────┘
```

| Endpoint | Auth | Does |
|---|---|---|
| `GET /v1/health` | none | `{ "ok": true }` |
| `POST /v1/auth/code` | none | Mails a 6-digit code; 204 for every address |
| `POST /v1/auth/verify` | none | Code -> `{ token, me }`; creates the account on the first sign-in |
| `POST /v1/auth/logout` | bearer | Revokes this session |
| `GET /v1/me` | bearer | Plan, Stripe status, period end, cancel flag, this month's usage and caps |
| `POST /v1/billing/checkout` | bearer | Checkout tied to the account (the app's "Przejdź na Pro") |
| `GET /v1/billing/checkout?plan=yearly\|monthly` | none | Checkout without an account (the site's "Wybierz Pro"); 303 to Stripe |
| `POST /v1/billing/portal` | bearer | Customer Portal ("Zarządzaj subskrypcją") |
| `POST /v1/stripe/webhook` | Stripe signature | Keeps `subscriptions` in step with Stripe |
| `POST /v1/chat/completions` | bearer, Pro | AI relay (OpenAI-style body, the server picks `PRO_AI_MODEL`) |
| `POST /v1/speech-to-text` | bearer, Pro | STT relay (the app's multipart upload, streamed) |

Tables (`server/migrations/`): `users` (e-mail, Stripe customer), `login_codes` (sha256 of the code, expiry, attempts), `sessions` (sha256 of the token, device, last use, revoked), `subscriptions` (Stripe subscription, status, plan, period start and end, cancel flag, the last applied event's `created`), `usage_monthly` (account, `YYYY-MM` in UTC, audio seconds, AI tokens), `stripe_events` (ids of applied events).

## Sign-in and sessions

- A 6-digit code by e-mail (Resend), no passwords. `POST /v1/auth/code` answers 204 for any address, so nobody learns whether an account exists. Codes are hashed, expire after 10 minutes, allow 5 attempts, and a new code spends the earlier ones. Limits: 5 codes per address per 15 minutes, 30 per IP per hour (in memory, one instance).
- A session token (43 characters) is stored hashed; it expires after `SESSION_DAYS` (180) unused. A wrong or revoked token answers 401.

## Payments

- Stripe directly on the owner's account: Checkout in subscription mode with Stripe Tax, tax id collection and promotion codes; the Customer Portal for cancelling, the payment method and invoices. Prices: yearly 159 PLN / 48 USD, monthly 24 PLN / 6 USD (one Price per period with `currency_options`).
- Two entry points. From the app, signed in: the Checkout carries the account (`customer`, `client_reference_id`) and returns to `captylo.com/pro/dziekujemy/?from=app`. From the site: no account yet, Stripe collects the e-mail, the webhook creates the account from it, the page `/pro/dziekujemy/?from=site` tells the user to sign in with that address. The Portal returns to `/pro/konto/`.
- Entitlement (`server/src/lib/entitlement.ts`): Pro while the subscription is `active` or `trialing`, and for 3 days from the start of the current period while it is `past_due`; otherwise Free. Each webhook event is applied once, in one transaction, and older events never overwrite newer state, revive a cancelled subscription or move an active one back to `incomplete`. A second subscription never replaces a paid, renewing one (it is logged as `duplicate_subscription` for a manual refund); a new paid one replaces an unpaid one (logged as `replaced_unpaid`, cancel the old one by hand). The app's Checkout answers 409 `payment_pending` while the subscription is `past_due` or `unpaid`, and the app shows "Płatność nie przeszła. Zaktualizuj kartę." with "Zarządzaj subskrypcją" instead of the buy buttons.

## Fair use

Monthly caps per account and UTC month, from env: `PRO_AUDIO_HOURS_PER_MONTH` (default 20) and `PRO_AI_TOKENS_PER_MONTH` (default 3,000,000). The check runs before the vendor is called; over the cap the relay answers 402 `{ "error": "quota_exceeded", "resetsAt" }`. Audio seconds are checked from the app's `X-Captylo-Audio-Seconds` header (1 to 14400 per request) and counted after the call as the larger of the header and what the vendor's answer shows (the last word's end over all channels, at least the transcript's length at 25 characters a second), because a modified client could declare less; the relay never decodes audio, and at most 3 uploads per account run at a time. Tokens come from the vendor's `usage`. The app treats 402 as "limit reached": the take falls back to the local model and the toast says why.

## Privacy promises (the site's policy depends on them)

- The relay streams uploads to the vendor and stores no audio and no text, on disk or in logs.
- Logs never contain an e-mail address, a login code, a token, a request body or a response body. Auth logs carry a hash of the address, relay logs a 16-hex pseudonym of the account, plus request id, route, status, time and the counted tokens or seconds.
- Vendor error texts never reach the client; clients get generic codes (`invalid_code`, `quota_exceeded`, `upstream_failed`, ...), details stay in the log under the request id.
- Processors named in the privacy policy (`site/prywatnosc/`): ElevenLabs (speech to text), OpenRouter and the model provider it routes to (AI), Stripe (payments), Resend (e-mail), Hetzner (hosting in the EU). A new processor or a new kind of stored data means updating that page first.

## App side

- `Captylo/Account/`: `AccountClient` (REST, `https://api.captylo.com/v1`, `CAPTYLO_API_BASE` overrides it for a local server), `AccountStore` (`@MainActor @Observable`: sign-in, the session token in the login Keychain as `captylo-account`, the last `/v1/me` cached in defaults `account.cache` / `account.refreshedAt`, refresh at launch and every 6 hours), `CloudRouter`, `CloudCredential`, `AIRoute`, `DeepLinkKind`. Views in `Captylo/UI/Main/Account/` ("Konto Captylo" in Ustawienia, the Pro card in Modele).
- `ProAccess` reads the plan from `AccountStore.isPro` (debug builds also accept "Tryb Pro (dev)" and `CAPTYLO_DEV_PRO=1`).
- Routing for every cloud request (`CloudRouter`): the user's own key -> the vendor directly, the chosen model honoured; otherwise a Pro session -> the relay (the server picks the model); otherwise no route (local only, with a hint). Own keys work in every plan and always win over Pro. The lookup is one cached Keychain read plus an in-memory Pro check, so the dictation deadline is unchanged.
- Offline: a cached Pro plan stays Pro for 7 days after the last successful `/v1/me`, then reads as Free until a refresh succeeds. A 401 signs out at once and clears the cache.
- Deep links: `captylo://pro/done` (from `/pro/dziekujemy/`) and `captylo://account/refresh` (from `/pro/konto/`) refresh the plan now, after 3 s and after 10 s (the webhook may lag the redirect).
- UI strings never name the vendors (see AGENTS.md); the relay is just "Captylo Pro".

## Deploy

Files in `server/Dockerfile` and `server/deploy/` (compose file, Caddy block, `deploy.sh`). `server/deploy/deploy.sh` syncs `server/` to `src/` in the stack folder on the server (`DEPLOY_HOST` and `DEPLOY_STACK` from the git-ignored `deploy/local.env`), builds and starts the stack and waits for the health check; migrations run at boot. Every production step needs the owner's go-ahead (see AGENTS.md and the procedure in `server/README.md`).

## Not built yet

Sync, a devices list, team plans, Sign in with Apple (can be added later as `users.apple_sub` without a schema rewrite), refund automation, invoices inside the app (the Portal has them), account deletion from the app (by e-mail for now), the 13-month purge of `usage_monthly` promised in the privacy policy, rate limits shared across instances.
