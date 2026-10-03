# Captylo API

The small HTTP service behind `api.captylo.com`: Captylo accounts, Pro subscriptions and the relay that runs cloud transcription and AI for Pro users with the server's keys. TypeScript on Node 22, [Hono](https://hono.dev), Postgres 17. Licensed like the app (GPLv3).

The server stores the account (e-mail address, sessions, subscription state) and monthly counts (audio seconds, AI tokens). It never stores or logs audio, text, login codes, tokens or e-mail addresses.

Status: configuration, migrations, health, sign-in with an e-mail code, sessions, `GET /v1/me`, Stripe Checkout, the Customer Portal, the Stripe webhook that keeps subscriptions, and the relay (AI chat and speech to text for Pro accounts, with monthly caps).

## Layout

| Path | What |
|---|---|
| `src/index.ts` | Boot: configuration, migrations, listen on `PORT` |
| `src/app.ts` | `buildApp(deps)`: the Hono app; every dependency is injected so tests pass fakes |
| `src/config.ts` | Environment parsing with defaults; fails fast on a bad or missing value |
| `src/db.ts` | `Db` interface over a `pg` pool, `migrate()` |
| `src/lib/` | One module per job: ids and hashes, JSON logger, rate limiter, request helpers, login codes, sessions, users, mail, the Stripe client subset, subscriptions, the entitlement rule, webhook event handling, monthly usage counters |
| `src/middleware/session.ts` | Bearer token -> signed-in user, 401 otherwise |
| `src/middleware/pro.ts` | Only Pro accounts pass, 403 `pro_required` otherwise |
| `src/routes/` | One file per group of endpoints |
| `migrations/*.sql` | Applied in name order at boot, once each (`schema_migrations`) |
| `test/` | Vitest; the database is [pglite](https://pglite.dev) in process, nothing reaches the network |
| `Dockerfile`, `deploy/` | Image, compose stack, Caddy block, deploy script |

## Endpoints

| Method and path | Auth | Does |
|---|---|---|
| `GET /v1/health` | none | `{ "ok": true }` |
| `POST /v1/auth/code` | none | Body `{ "email" }`. Mails a 6-digit code valid for 10 minutes and answers 204 for every address, known or not (400 only when the field is missing or not an e-mail, 502 `mail_failed` when the mail cannot be sent). A new code spends the earlier ones. Limits: 5 codes per address per 15 minutes, 30 per IP (first `X-Forwarded-For` value) per hour; over a limit it still answers 204 and sends nothing |
| `POST /v1/auth/verify` | none | Body `{ "email", "code", "device" }`. 200 `{ "token", "me" }` (the token is 43 characters, base64url) or 400 `{ "error": "invalid_code" }` for every kind of failure. Five attempts per code, then it is spent. Creates the account on the first sign-in |
| `POST /v1/auth/logout` | bearer | Revokes this session, 204 |
| `GET /v1/me` | bearer | `{ email, plan, status, periodEnd, cancelAtPeriodEnd, usage: { month, audioSeconds, audioSecondsLimit, aiTokens, aiTokensLimit } }`. `plan` is `pro` while the subscription is `active` or `trialing`, and for 3 days from the start of the current period while it is `past_due` (the card retry window; Stripe moves the period forward when it creates the renewal invoice, before it charges the card, so the period end is a month or a year ahead by then); otherwise `free`. `status` is Stripe's status (null without a subscription), `periodEnd` an ISO date. `usage` is this month's relay counters (UTC) and the caps |
| `POST /v1/billing/checkout` | bearer | Body `{ "plan": "yearly" \| "monthly" }`. 200 `{ "url" }` of a Stripe Checkout tied to this account (the Stripe customer is created on the first call). 409 `already_pro`; 409 `payment_pending` while the stored subscription is `past_due` or `unpaid` (Stripe still retries the card, a second subscription could charge twice; the app offers the Portal instead); 400 `bad_request` for another plan |
| `GET /v1/billing/checkout?plan=yearly\|monthly` | none | The site's "Wybierz Pro" button: 303 to a Checkout with no account; Stripe collects the e-mail and the webhook creates the account, the user then signs in with that address. 400 for another plan, 429 above 20 per IP per hour |
| `POST /v1/billing/portal` | bearer | 200 `{ "url" }` of the Stripe Customer Portal (returns to `/pro/konto/` on the site); 404 `no_customer` for an account that never paid |
| `POST /v1/stripe/webhook` | Stripe signature | See "Stripe" below. 400 `bad_signature` for a missing or wrong `Stripe-Signature` |
| `POST /v1/chat/completions` | bearer, Pro | The AI relay, see "Relay" below |
| `POST /v1/speech-to-text` | bearer, Pro | The speech-to-text relay, see "Relay" below |

Bearer means `Authorization: Bearer <token>`; a missing, revoked or expired token (unused for `SESSION_DAYS`) answers 401 `{ "error": "unauthorized" }`. The database keeps only sha256 hashes of codes and tokens. The auth bodies are capped at 8 KB (413 `too_large`).

A failed Stripe call answers 502 `{ "error": "billing_unavailable" }` (503 when a price or the key is not configured); the log keeps Stripe's error type and code, never its message.

Every response carries `X-Request-Id` (16 hex characters, also in each log line). Errors are JSON with a generic code (`{ "error": "not_found" }`); a crash answers `{ "error": "internal", "requestId": "..." }` and the details stay in the log.

## Stripe

The server speaks Stripe API version `2026-08-26.dahlia` (the one stripe-node 22.6 is typed for, `src/lib/stripe.ts`). Checkout runs in subscription mode with Stripe Tax (`automatic_tax`), tax id collection and promotion codes; each plan is one Price with `currency_options` (PLN and USD), and the plan is also written to `subscription.metadata.plan`.

Webhook endpoint: `https://api.captylo.com/v1/stripe/webhook`, created with the API version above, listening to:

- `checkout.session.completed`: finds the account by `client_reference_id` (the app's Checkout), else by the Stripe customer, else by the e-mail Stripe collected (created when missing: the site's Checkout); stores the subscription (fetched from Stripe once) and links its customer to the account, replacing an older customer (the site's Checkout always makes a new one, and the Portal must open for the customer that pays) unless another account holds it. Sessions in `payment` mode (one-off payments on the same Stripe account) are ignored.
- `customer.subscription.created`, `customer.subscription.updated`, `customer.subscription.deleted`: updates the stored subscription, found by its id or by the customer; a subscription of an unknown customer or to another price is ignored (logged).
- `invoice.paid`, `invoice.payment_failed`: logged only; the subscription events carry the status.

Each event is applied once (`stripe_events`) inside one transaction; a failure answers 500 and records nothing, so Stripe delivers it again. Ordering: an event older than the stored one (`event_created`) is skipped, a canceled subscription is never revived, a subscription that has moved on never goes back to `incomplete` (the Checkout's `customer.subscription.created` often shares its second with the `updated` to `active` and may arrive after it), and a late event of an old, ended subscription never replaces a live one. The period start and end are read from the subscription item (`items.data[0].current_period_start` and `current_period_end`, API 2025-03 and later) with the old top-level fields as a fallback.

Second subscriptions: an account has one stored subscription. A different one never replaces a stored subscription that is `active` or `trialing` and renews (a site Checkout typed with the address of an account that already pays, two Checkouts opened in parallel): the stored row and the account's customer stay, and the event logs a warning with the outcome `duplicate_subscription`. Refund and cancel that new subscription by hand in the Dashboard. A new live subscription does replace one that is `past_due` or `unpaid` (or set to end at the period end), so a user who paid again has Pro; when the old one was unpaid the event logs a warning `replaced_unpaid`: cancel the old subscription in the Dashboard so a late successful retry cannot charge twice.

Failed payments: `past_due` keeps Pro for only 3 days from the start of the unpaid period, but the subscription stays `past_due` until Stripe gives up. Set Billing > Subscriptions and emails > Manage failed payments to cancel the subscription after the retries fail, so the status ends in `canceled` instead of lingering.

## Relay

Pro accounts get cloud transcription and AI without keys of their own: the app sends the same request it would send to the vendor, with its session token instead of a key, and the relay forwards it with the server's key. Both endpoints need a session (401) and a Pro plan (403 `pro_required`, read on every request, so a cancelled subscription stops at once).

- `POST /v1/chat/completions`: an OpenAI-style chat body of at most 2 MB (413 `too_large`), with a non-empty `messages` array (400 otherwise). The relay replaces `model` with `PRO_AI_MODEL` and forwards only `messages`, `temperature`, `max_tokens`, `reasoning`, `provider.sort` and `stream`; anything else (fallback model lists, plugins, provider pinning) is dropped, so a token cannot choose a pricier model or feature. The vendor's answer is passed through; tokens are counted from its `usage.total_tokens`, or estimated as a quarter of the request and answer bytes when it reports none. With `stream: true` the event stream is passed through chunk by chunk and the final usage chunk is counted when the stream ends.
- `POST /v1/speech-to-text`: the app's `multipart/form-data` upload, streamed to the vendor unchanged (never held in memory or on disk; the Content-Length is passed on when the app sends one). The header `X-Captylo-Audio-Seconds` (whole seconds, 1 to 14400 = 4 hours) is required (400 otherwise) and is checked against the cap before the call. On success the month's audio counter adds the larger of the header and what the vendor's answer shows was transcribed: the latest word end over every channel (`words[].end`, or `transcripts[].words[].end` for multichannel), and at least the transcript's length at 25 characters a second (faster than anyone speaks, for an answer without word times). The client and the protocol are public, so the header alone could be forged; a mismatch logs a warning `stt seconds under-declared` with both numbers. At most 3 uploads per account run at a time (429 `too_many_requests`), which bounds how far parallel uploads can pass the cap. Uploads above 220 MB (Caddy's limit too) answer 413.

Caps: `PRO_AI_TOKENS_PER_MONTH` and `PRO_AUDIO_HOURS_PER_MONTH` per account and UTC month (`usage_monthly`). The check runs before the vendor is called: AI is refused once the month's tokens reached the cap (the size of a request is known only after the answer, so the last one may go a little over), audio when this request's seconds would pass it. Over the cap: 402 `{ "error": "quota_exceeded", "resetsAt": "<first day of next month, ISO>" }`. The audio seconds are checked from the app's header before the call and counted from the header or the vendor's answer, whichever is larger, after it; the relay never decodes audio.

Vendor errors become generic codes and the vendor's text is dropped: 429 -> 429 `upstream_busy`; a rejected input -> 400 `upstream_rejected` (for speech, the vendor's 422 -> 422 `bad_audio`); anything else, including a refused server key or an unreachable vendor -> 502 `upstream_failed`. A failed request counts nothing. A missing key on the server answers 503 `relay_unavailable`. The vendor call ends when the app disconnects, after 5 minutes for AI and 15 minutes for speech (Caddy's read timeout).

Each relay request logs one line: request id, a 16-hex pseudonym of the account (sha256), route, status, milliseconds and the tokens or seconds counted (plus the vendor's status on an error). Never the text, the audio, the transcript, a token or a key.

## Configuration

All settings come from the environment; `.env.example` lists them with the defaults.

| Variable | Default | Notes |
|---|---|---|
| `NODE_ENV` | `development` | `production` requires every secret below |
| `PORT` | `8080` | |
| `DATABASE_URL` | none, required | `postgres://...`; the password may come from `PGPASSWORD` instead; on the VPS the compose file sets both (the password from `POSTGRES_PASSWORD`) |
| `PUBLIC_SITE_URL` | `https://captylo.com` | Checkout return pages |
| `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET` | blank | Required in production |
| `STRIPE_PRICE_YEARLY`, `STRIPE_PRICE_MONTHLY` | blank | Required in production (`price_...`) |
| `RESEND_API_KEY` | blank | Mail key for the login codes, required in production; blank in development keeps the messages in memory and sends nothing (codes are never written to the log, so a local sign-in needs a real or test key) |
| `MAIL_FROM` | `Captylo <konto@captylo.com>` | |
| `OPENROUTER_API_KEY` | blank | AI relay key, required in production |
| `OPENROUTER_BASE_URL` | `https://openrouter.ai/api/v1` | |
| `PRO_AI_MODEL` | `google/gemini-2.5-flash-lite` | The relay always uses this model |
| `STT_API_KEY` | blank | Speech-to-text relay key, required in production |
| `STT_BASE_URL` | `https://api.elevenlabs.io/v1` | |
| `PRO_AUDIO_HOURS_PER_MONTH` | `20` | Fair use cap per account and month (UTC) |
| `PRO_AI_TOKENS_PER_MONTH` | `3000000` | Fair use cap per account and month (UTC) |
| `SESSION_DAYS` | `180` | A session unused this long expires |

## Local development

```sh
cd server
npm ci
npm test            # Vitest, pglite in process, no network
npm run build       # tsc into dist/
npm run typecheck   # src and tests
```

To run the service locally you need a Postgres 17, for example `docker run --rm -e POSTGRES_PASSWORD=captylo -e POSTGRES_USER=captylo -e POSTGRES_DB=captylo -p 5432:5432 postgres:17-alpine`, then:

```sh
PGPASSWORD=captylo DATABASE_URL=postgres://captylo@127.0.0.1:5432/captylo npm run dev
curl http://127.0.0.1:8080/v1/health
```

## Deploy (VPS)

The host and the stack folder come from `deploy/local.env` at the repo root (git-ignored, template `deploy/local.env.example`: `DEPLOY_HOST`, `DEPLOY_STACK`). The stack folder holds `docker-compose.yml`, `.env` and the sources in `src/`; two containers (`captylo-api`, `captylo-api-postgres` with a named volume); no published ports, Caddy reaches `captylo-api:8080` over the external `proxy` network; logs are json-file, 10 MB x 3.

First time only:

1. Create the `DEPLOY_STACK` folder on the server and `.env` in it from `.env.example` (`chmod 600`). Secrets are pasted on the VPS, never into the repo or a chat.
2. DNS: `A api -> <VPS address>`.
3. Caddy: back up the Caddyfile, append `deploy/Caddyfile.snippet` (the block between the `# === captylo-api ===` markers), validate, reload. The access log keeps the path, status and timing only: the block's `format filter` drops the client address, port and all request and response headers, and the API never takes an e-mail address in a URL. The server purges login codes a day after they expire and usage counters older than 13 months at boot and every 6 hours (`src/lib/purge.ts`).

Every deploy, from the repo root on the Mac:

```sh
server/deploy/deploy.sh
```

It syncs `server/` (without `node_modules`, `dist` and `.env`) to `src/`, copies the compose file, runs `docker compose build --pull` and `up -d`, then waits until the container reports healthy. Migrations run at boot. Check from outside with `curl https://api.captylo.com/v1/health`.
