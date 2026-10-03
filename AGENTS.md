# Captylo

Minimalist macOS dictation app: hold a hotkey, speak, the text lands at the cursor. Tagline: "Mów, a tekst pojawia się tam, gdzie piszesz." Local Whisper large-v3-turbo (WhisperKit) by default, ElevenLabs Scribe as the optional cloud engine, optional OpenRouter cleanup. It also takes meeting notes on the Mac (mic + system audio, no bot, live local transcript; AI notes and speaker labels in Pro). Clean rewrite of an older VoiceInk-based app, not a fork (its behaviour is mapped in `docs/reference/port-notes/`).

**Identity**: bundle `com.captylo.app`, product `Captylo.app` (executable `Captylo`), data in `~/Library/Application Support/Captylo/`, Keychain service and log subsystem `com.captylo.app`, URL scheme `captylo`, website https://captylo.com, macOS 14.4+, arm64 only.

**Open source**: public repo https://github.com/dawidkawalec/captylo under GPLv3 (`LICENSE`); third-party components and their licences in `NOTICE.md`. The Captylo name, logo and icon are not licensed for forks. Everything committed is public, history included: no secrets, no personal data, no real dictations in fixtures or screenshots.

**Plans**: Free = unlimited local dictation, plus cloud transcription and AI modes with the user's own keys (own keys work in every plan, never gate them behind Pro). Pro = the same with no keys to set up, on a Captylo account (e-mail code sign-in, Stripe subscription) through our relay `api.captylo.com` ([docs/pro-backend.md](docs/pro-backend.md), built in M4). An own key always wins over Pro; the relay is used only without one.

## Stack

- **App**: Swift 6 (strict concurrency), SwiftUI + AppKit panels → `Captylo/`
- **Project**: XcodeGen `project.yml` → generated `Captylo.xcodeproj` (git-ignored, never hand-edit)
- **Speech**: WhisperKit 1.1.0 (argmax-oss-swift, Whisper large-v3-turbo `openai_whisper-large-v3-v20240930`, Core ML on the Neural Engine), ElevenLabs `scribe_v2` → `Captylo/Transcription/`; FluidAudio 0.17.4 only for the meeting VAD (Silero) and diarization
- **AI cleanup**: OpenRouter chat completions, model picked by the user → `Captylo/Enhancement/`
- **Meetings (notetaker)**: mic + Core Audio system tap as two tracks, live local Whisper per track, call detection (mic use, app quit, browser tabs), optional calendar through EventKit (Free: event title, participants, "Nadchodzące", reminders before a call; never auto-starts), launch resume of the AI steps, experimental echo reduction, ⌃⌥⌘M, full-text search over every meeting (own SQLite FTS5 trigram index `Search.sqlite`, Polish inflection, hit lines that jump into the transcript), a local read-only MCP server for the user's AI assistant (`--mcp`, off by default, Free); in Pro after the meeting: cloud transcript (Scribe), AI fixes of the transcript, speaker labels, AI notes, "Zapytaj" about one meeting or all of them with `[mm:ss]` / `[S1 12:34]` citations → `Captylo/Meetings/` (`Search/`, `AI/`, `MCP/`), views in `Captylo/UI/Meetings/` (section "Spotkania (notetaker)" in [docs/architecture.md](docs/architecture.md))
- **Data**: SwiftData store (dictations, meetings, meeting segments) + `dictionary.json` + WAV recordings + meeting CAF tracks → `Captylo/Data/`, `Captylo/Text/`
- **Tests**: Swift Testing → `CaptyloTests/`
- **Account and Pro (app)**: `AccountStore`, `CloudRouter` (own key → vendor, else Pro → relay, else local), deep links `captylo://pro/done` and `captylo://account/refresh` → `Captylo/Account/`, views in `Captylo/UI/Main/Account/` (section "Account and Pro" in [docs/architecture.md](docs/architecture.md))
- **Updates**: Sparkle 2.9.4 behind `AppUpdater` (appcast `captylo.com/updates/appcast.xml`, EdDSA public key from `SPARKLE_PUBLIC_ED_KEY` in `project.yml`, off while it is `REPLACE_ME`); started only by `startServices()`, never in the design preview or the test host → `Captylo/App/AppUpdater*.swift`, `Captylo/UI/Main/UpdatesRow.swift` (row "Updates" in [docs/architecture.md](docs/architecture.md))
- **Server**: `api.captylo.com` (accounts, Stripe subscriptions, the Pro relay with monthly caps): TypeScript on Node 22, Hono, Postgres 17, Vitest with pglite → `server/` (own `package.json`; details in [server/README.md](server/README.md))
- **Website**: static landing page → `site/` (captylo.com), plus `pro/dziekujemy/`, `pro/konto/` (return pages from Stripe), `prywatnosc/` (privacy policy), `regulamin/` (Pro terms)

## Commands

```bash
make gen      # xcodegen generate (run after adding/removing files)
make build    # Debug build into .local-build/
make test     # unit tests
make release  # Release build, copies "Captylo.app" to ~/Downloads, signs it inside-out with "Captylo Dev" (or ad-hoc)
scripts/sign-app.sh <app> <identity> [--entitlements F] [--keychain F] [--no-timestamp]   # inside-out codesign (Sparkle helpers first)
make dist VERSION=x.y.z      # public release into dist/: Developer ID, notarization, stapled DMG, appcast (owner, docs/release.md)
make dist-dry VERSION=x.y.z  # the same signed with "Captylo Dev", no notarization, nothing leaves the Mac
make publish-check VERSION=x.y.z   # local checks before publishing; make publish uploads (owner only, asks first)
python3 -m unittest scripts/test_appcast.py   # appcast, notes, site version and publish-check tests
make run      # launch the last build
make check    # Debug binary --check: permissions, model, paths as JSON
scripts/snap.sh <target> <out.png>   # screenshot one screen from the design preview (fake data, no services)
scripts/make-dusk-video.sh           # re-render Resources/Video/dusk-loop.mp4 (the "Zmierzch" loop) from our dusk photo
cd server && npm ci && npm test      # server tests (Vitest, pglite in process, never the network)
cd server && npm run build           # server typecheck + build (tsc into dist/)
```

## Docs

- [README.md](README.md) - what Captylo is, requirements, build (incl. the paste-to-an-AI-agent install prompt), privacy, licence
- [NOTICE.md](NOTICE.md) - third-party code, models, fonts and their licences
- [docs/pro-backend.md](docs/pro-backend.md) - accounts, Pro and the relay: architecture, endpoints, tables, payments, fair use, privacy promises, the routing rule in the app
- [server/README.md](server/README.md) - the API service in detail: every endpoint, Stripe events, the relay, env variables, local development, deploy
- [docs/architecture.md](docs/architecture.md) - modules, decisions, data flow, debug CLI flags
- [docs/release.md](docs/release.md) - cutting a public release: one-time keys and server setup, `make dist`, `make publish`, rejected notarization, key backups
- [docs/coding-standards.md](docs/coding-standards.md) - Swift 6 rules, UI language, naming
- [docs/reference/port-notes/REWRITE-BRIEF.md](docs/reference/port-notes/REWRITE-BRIEF.md) - gotchas from the old app (87 numbered), formulas, API specs (historical, names and ids there are pre-rename)
- [docs/design/dusk-glass.md](docs/design/dusk-glass.md) - Dusk Glass design language in Deep Tide (binding for all UI): Grainient background, clear glass, Manrope + Inter, Glass components, design preview targets
- [docs/design/website.md](docs/design/website.md) - captylo.com in Deep Tide: tide blocks with the Grainient, the hero demo, how to regenerate screenshots and the OG image
- [docs/design/](docs/design/) - widget mockups, HTML labs (`lab/brand`, `lab/pulpit`); [branding/direction-01/](branding/direction-01/) - current logo, icon, wordmark (generated by `brand.py`)

## Critical Rules

- `docs/architecture.md` wins over the port notes when they disagree; the port notes win over memory.
- The product name is "Captylo" everywhere users look (UI, site, docs, file names); the only public web address is captylo.com.
- Never show the cloud vendors' names (ElevenLabs, OpenRouter, "Scribe", vendor URLs) where users look: UI strings, error texts, history labels, the site, README, marketing. Say "chmura" / "AI"; history and CSV map the cloud model id through `STTEngine.label(forModelName:)`. Type names, logs and these developer docs keep the real names. The only exception is the site's privacy policy and terms (`site/prywatnosc/`, `site/regulamin/`), which must name every processor.
- The server (`server/`) never logs or stores audio or text, and never logs an e-mail address, a login code, a token, a request body or a response body; clients get generic error codes. A new processor or a new kind of stored data means updating `site/prywatnosc/` and `docs/pro-backend.md` first. Pro gating goes only through `ProAccess`; own keys work in every plan and always win over the relay.
- Swift 6 language mode, no default MainActor isolation: annotate UI/AppKit types `@MainActor`, keep audio callbacks nonisolated.
- UI strings are Polish in code (`String(localized:)` / SwiftUI literals) with English in `Localizable.xcstrings`; never hardcode English UI text.
- Never write error text into transcript fields; use `errorMessage`. Never remove real Polish words deterministically.
- No new dependencies without a note in `docs/architecture.md` and an entry in `NOTICE.md` (GPLv3-compatible licences only). No secrets in the repo; API keys live in the login Keychain.
- Meeting audio never goes under `Recordings/` (the dictation orphan sweep would delete it): it lives in `AppPaths.meetings/<meetingID>/` (`me.caf`, `them.caf`).
- One local engine: `WhisperEngine` (one `WhisperKit` instance, passes serialized; previews never wait and stop decoding when a final pass is waiting). Never claim in marketing that the local model matches the cloud; the cloud is the accuracy reference. Meeting utterances stay at most 14 s (28 s measured worse); `EchoFilter` flags whole echo segments and cuts 4+ word echo runs out of mixed ones by word times.
- Diarization (speaker labels) only on macOS 15+: FluidAudio's offline diarizer crashes on macOS 14 (FluidAudio #878). Pro features go through `ProAccess` only.
- Meetings never record or stop without a visible prompt or click; a recording always shows the live bar and the menu bar state. The calendar never starts a recording on its own (a reminder always asks), calendar features stay Free, and event titles or attendee names are never logged (`Log.calendar` logs states and counts only). The design preview and the test host never create an `EKEventStore`.
- Every store write that changes searchable meeting text (segments, echo marks, title, notes, replace, restore, delete, launch recovery) also updates the search index through `Database.searchIndex`; the index never stores original text and can always be rebuilt from the store. The design preview and the test host get an in-memory index, never the real file.
- The MCP mode (`--mcp`) stays read-only and offline: the store opened with `allowsSave: false` (never migrated), the index with `SQLITE_OPEN_READONLY`, no AI calls, nothing on stdout but JSON-RPC lines, off until the user turns on "Dostęp dla asystentów AI (MCP)". Never run it against the owner's real data folder in checks: use `CAPTYLO_DATA_DIR` with a copy.
- After adding files run `make gen`; a change is done only when `make build` and `make test` pass (and, for `server/`, `npm test` and `npm run build` there). Server tests never reach the network: Stripe, the mailer and the vendors are fakes. Secrets live only in `.env` on the VPS; the repo has `server/.env.example`.
- Signing: public releases are signed only with "Developer ID Application" through `make dist` (hardened runtime, timestamp, notarized, stapled); development builds use ad-hoc or the local "Captylo Dev" identity, never Developer ID. The notary profile (`captylo-notary`), the Developer ID key and Sparkle's EdDSA private key live only in the owner's login Keychain (backups in a private folder outside the repo); never commit a `.p12`, `.p8`, key or password, and never run notarization, `generate_keys`, `make publish` or `gh release` without the owner's go-ahead. `SPARKLE_PUBLIC_ED_KEY` in `project.yml` is public. DMGs live in `dist/` (git-ignored) and on the server in their own folder outside the site's web root. The server's name and folders live only in `deploy/local.env` (git-ignored, template `deploy/local.env.example`), never in committed files: the repo is public.
