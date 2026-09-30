# Pro backend (plan, not built)

Status: planned. Nothing here exists yet; the app today runs cloud transcription and AI modes only with the user's own keys, in every plan. This page fixes the shape so the app side can be prepared without guessing.

## Why a server

Free users paste their own keys (Settings, Modele) and talk to the providers directly. Pro users must get cloud transcription and AI modes with no setup, so the requests have to go out with **our** keys. A key shipped inside the app can be extracted from the binary (and this repo is public), so Pro traffic goes through a small relay that holds the keys server side and checks the subscription first.

## Shape

One small HTTP service (working name `api.captylo.com`), stateless apart from a subscriptions table:

| Endpoint | Does |
|---|---|
| `POST /v1/chat/completions` | OpenAI-compatible relay to the AI provider with our key. The server picks the model (a cheap, fast one), so it can change without an app update; the `model` the app sends is ignored. |
| `POST /v1/speech-to-text` | Relay to the cloud STT with the same multipart body the app sends to ElevenLabs today. |
| `GET /v1/me` | Plan, renewal date and this month's usage, for the Settings screen. |
| `POST /v1/stripe/webhook` | Subscription created, renewed, cancelled: updates the subscriptions table. |

- **Auth**: after checkout the user gets a licence token (email link or deep link `captylo://pro?token=...`). The app stores it in the login Keychain as a new `KeyStore` account (`captylo-pro`) and sends `Authorization: Bearer <token>`.
- **Payments**: Stripe subscriptions (159 zł / year, 24 zł / month), the same Stripe account as the `/kawa/` Payment Link.
- **Fair use**: a monthly cap per account (audio minutes and AI tokens) sized so 24 zł covers the provider cost with room to spare; over the cap the app falls back to local transcription and says why.
- **Privacy**: the relay never stores audio or text and logs only counts (requests, seconds, tokens) per account. The privacy text on the site and in the README must stay true.

## App side

- Routing order for a cloud request: the user's own key → provider directly; otherwise a Pro token → our relay; otherwise local only (cloud and AI switched off with a hint).
- `OpenRouterClient` already takes a `baseURL`, so Pro only passes the relay URL and the token instead of the user's key.
- `ElevenLabsSTT` has hard-coded `transcribeURL` / `userURL`; make them injectable like `OpenRouterClient.baseURL` and send `Authorization: Bearer` instead of `xi-api-key` when talking to the relay.
- Settings, Modele: a Pro card (status from `/v1/me`, "Zarządzaj subskrypcją" link) above the own-key fields, which stay available in every plan.
- UI strings never name the vendors (see AGENTS.md); the relay is just "Captylo Pro".

## Open questions

- Which AI model and which STT tier for Pro (cost per minute vs quality in Polish).
- Hosting: our VPS behind Caddy, or a serverless function with a small database.
- Licence token flow: magic link by email vs sign in with Apple.
