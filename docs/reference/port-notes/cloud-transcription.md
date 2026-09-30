# Port note: Cloud transcription providers (batch STT)

Scope: the batch (non-streaming) cloud speech-to-text path of the old app, plus API key storage and verification.
Realtime/WebSocket clients are listed briefly in section 7 only (separate subsystem).

## 1. What it does for the user

- User pastes an API key for a provider once, the app verifies it with a cheap GET, saves it to the Keychain, and the provider's models become selectable.
- After recording stops, the WAV file is uploaded to the selected provider and the returned text goes into the normal post-processing / paste pipeline.
- The same path is used by the "transcribe an audio file" feature (the file is first converted to the same WAV format).
- When realtime streaming fails, the streaming session falls back to this batch path (`TranscriptionSession.swift`, `StreamingTranscriptionSession`).
- The user's dictionary (SwiftData `VocabularyWord`) is sent as keyterms to the providers that support it.

What the user actually uses: local Parakeet (not cloud). Cloud is a secondary option: Groq has a key, and Gemini was tried in onboarding.

**DROP (bloat):**
- 10 providers with per-provider language tables, fake `speed`/`accuracy` scores, marketing descriptions, and 13 Gemini model ids (several look invented or retired, see 3.3).
- A "custom cloud model" CRUD (a list of models in UserDefaults, a Keychain key per model UUID, a connection tester). Replace it with ONE optional "OpenAI-compatible endpoint" setting.
- Onboarding cloud provider picker with 10 options sorted by `preferredOrder`.
- Three different UI flows that each verify and save keys (`CloudModelCardView`, `ProviderDetailPanel`, `OnboardingTranscriptionSetupCard`). One shared function is enough.
- AssemblyAI, Speechmatics, Soniox batch (they need upload + create job + 1 s polling, which is slow for dictation), Cartesia (English-only, streaming-only), xAI and Mistral (weak or undeclared Polish, and not used).
- The LLMkit SPM dependency for STT. The whole batch layer is about 300 lines of plain `URLSession`.

## 2. Key files and control flow

Old app (`<old repo>/VoiceInk`):
- `Transcription/Cloud/CloudProvider.swift`: `protocol CloudProvider` + `CloudProviderRegistry.allProviders`.
- `Transcription/Cloud/*Provider.swift`: thin wrappers (model list + calls into LLMkit clients).
- `Transcription/Cloud/CloudTranscriptionService.swift`: loads audio, resolves the key, collects vocabulary, and maps errors.
- `Transcription/Cloud/OpenAICompatibleTranscriptionService.swift`: the "custom" provider (the user supplies the full endpoint URL).
- `Transcription/Cloud/CustomModelConnectionTester.swift`: probes a custom endpoint with junk audio.
- `Services/KeychainService.swift`, `Services/APIKeyManager.swift`: key storage.
- `Transcription/Engine/TranscriptionService.swift`: `TranscriptionRequestContext` (language from UserDefaults `SelectedLanguage`, default `"en"` in `AppDefaults.swift`!).
- `Transcription/Engine/TranscriptionModelManager.swift:60`: a cloud model counts as "usable" iff `APIKeyManager.hasAPIKey(provider)`.

HTTP clients live in the LLMkit package (checked out at
`<old repo>/.local-build/SourcePackages/checkouts/LLMkit/Sources/LLMkit/`, commit `3b9086e`):
`HTTPClient.swift` (retry + ephemeral session), `MultipartFormData.swift`, `HTTPHelpers.swift`, `Transcription/*Client.swift`.

Flow:
```
stop recording -> WAV file URL
  -> TranscriptionServiceRegistry.service(for: model.provider)   // any non-local provider -> CloudTranscriptionService
  -> CloudTranscriptionService.transcribe(audioURL, model, context)
       audioData = Data(contentsOf: url)                          // whole file in memory
       language  = context.language == "auto" || "" ? nil : lang
       apiKey    = APIKeyManager.getAPIKey(provider.providerKey) else .missingAPIKey
       vocab     = VocabularyWord sorted by word, trimmed, case-insensitive dedup
       provider.transcribe(audioData, fileName, apiKey, model.name, language, vocab)
  -> errors mapped: LLMKitError -> CloudTranscriptionError
```
`context.scoped(to:)` drops the free-text `prompt` for every non-Whisper model, so cloud providers never receive `TranscriptionPrompt`.

## 3. Exact technical details

### 3.1 Audio sent
- The recorder (`CoreAudioRecorder.swift:452`) writes **WAV, 16 kHz, mono, PCM signed Int16, packed** via `ExtAudioFileCreateWithURL(..., kAudioFileWAVEType, ...)`. That is 32 KB/s, about 1.9 MB/min.
- File transcription: `AudioFileProcessor` decodes to 16 kHz mono Float32, then `saveSamplesAsWav` writes Int16 WAV. Same format.
- Every provider gets MIME `audio/wav`, file name = `audioURL.lastPathComponent`.
- Size limits to respect in the rewrite: Groq and OpenAI allow 25 MB per upload (about 13 min of this WAV). Gemini inline data has a ~20 MB total request limit, and base64 adds 33%, so the ceiling is about 7-8 min. For longer files, encode to FLAC/M4A or chunk. The old app does neither.

### 3.2 Shared HTTP behaviour (LLMkit `HTTPClient.swift`)
- `performUpload` / `performRequest`: `maxRetries = 2`, backoff 1 s then 2 s. Retries on HTTP 429/500/502/503/504 and on network errors. A timeout (`NSURLErrorTimedOut`) is NOT retried; it throws `.timeout` immediately.
- **A new ephemeral `URLSession` per attempt**, with `timeoutIntervalForRequest = timeoutIntervalForResource = timeout`, cache disabled. The reason is a workaround (comment in `OpenAICompatibleTranscriptionService.swift`): the shared session remembers Alt-Svc and upgrades to HTTP/3. QUIC bulk uploads get blackholed behind VPNs that drop full-size UDP datagrams (GlobalProtect), so large uploads time out. **Keep this.**
- Because `timeoutIntervalForResource == timeout`, the entire upload + response must finish within 30-60 s. That is fine for dictation and risky for long files on a slow uplink.
- Non-2xx response: `httpError(status, rawBodyString)`. The UI shows the raw body.
- Key verification functions use `URLSession.shared`, a 10 s timeout, no retry. Any 2xx means valid, and otherwise the raw body is the error text.
- Polling loops (Soniox, AssemblyAI, Speechmatics) use `URLSession.shared` with no retry, 1 s sleep, and a 300 s cap.

### 3.3 Per-provider reference (batch)

| Provider | Endpoint | Auth header | Body | Model ids | Language param | Vocabulary param | Text path | Timeout |
|---|---|---|---|---|---|---|---|---|
| **Groq** | `POST https://api.groq.com/openai/v1/audio/transcriptions` | `Authorization: Bearer <key>` | multipart: `file` (audio/wav), `model`, [`language`], [`prompt`], `response_format=json`, `temperature=0` | `whisper-large-v3-turbo` | `language` (ISO-639-1, e.g. `pl`), omitted = auto | **not sent** (client supports `prompt`, provider ignores vocab) | `$.text` (falls back to raw body string) | 60 s |
| **Gemini** | `POST https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent` | `x-goog-api-key: <key>` | JSON (below), audio inline base64 | 13 ids (see note) | **not sent** | **not sent** | `$.candidates[0].content.parts[0].text`, trimmed | 60 s |
| **ElevenLabs** | `POST https://api.elevenlabs.io/v1/speech-to-text` | `xi-api-key: <key>`, `Accept: application/json` | multipart: `file`, `model_id`, `temperature=0.0`, `tag_audio_events=false`, [`language_code`], `no_verbatim=true`, repeated `keyterms` | `scribe_v2` | `language_code` | `keyterms` (repeated field; filtered: <=50 chars, <=5 words, no `<>{}[]\`, dedup, max 1000) | `$.text` | 30 s |
| **Deepgram** | `POST https://api.deepgram.com/v1/listen?model=..&smart_format=true&punctuate=true&paragraphs=true[&language=..][&keyterm=..]*` | `Authorization: Token <key>` | raw WAV bytes, `Content-Type: audio/wav` | `nova-3`, `nova-3-medical` | `language` query | `keyterm` query (supported by client, **provider does not pass vocab**) | `$.results.channels[0].alternatives[0].transcript` | 30 s |
| **Mistral** | `POST https://api.mistral.ai/v1/audio/transcriptions` | `x-api-key: <key>` (verify uses Bearer) | multipart: `model`, `file` | `voxtral-mini-latest` | **not sent** | not sent | `$.text` | 30 s |
| **xAI** | `POST https://api.x.ai/v1/stt` | `Authorization: Bearer <key>`, `Accept: application/json` | multipart: [`language`, `format=true`], then `file` **last** (xAI requirement) | `grok-stt` (display only, not sent) | `language` | not sent | `$.text` | 60 s |
| **AssemblyAI** | `POST /v2/upload` (raw octet-stream) -> `POST /v2/transcript` JSON -> poll `GET /v2/transcript/{id}` on `https://api.assemblyai.com` | `Authorization: <key>` (no Bearer) | create: `{audio_url, speech_models:[model], punctuate:true, format_text:true, language_code \| language_detection:true, keyterms_prompt:[..]}` | `universal-3-5-pro` (no `pl`!), `universal-2` | `language_code` | `keyterms_prompt` (<=50 chars, <=6 words, max 200 for u2 / 1000) | poll until `status=="completed"` -> `$.text`; `"error"` -> `$.error` | 30 s/req, 300 s total |
| **Soniox** | `POST /v1/files` multipart `file` -> `POST /v1/transcriptions` JSON -> poll `GET /v1/transcriptions/{id}` -> `GET /v1/transcriptions/{id}/transcript` on `https://api.soniox.com` | `Bearer` | `{file_id, model, enable_speaker_diarization:false, context:{terms:[..]}, language_hints:[lang], language_hints_strict:true, enable_language_identification:true}` | `stt-async-v5` | `language_hints` | `context.terms` | `status=="completed"` then `$.text` of the transcript | 30 s/req, 300 s total |
| **Speechmatics** | `POST https://asr.api.speechmatics.com/v2/jobs` multipart (`config` = JSON string, `data_file`) -> poll `GET /v2/jobs/{id}` -> `GET /v2/jobs/{id}/transcript?format=txt` | `Bearer` | config `{"type":"transcription","transcription_config":{"language":lang\|"auto","operating_point":"enhanced","additional_vocab":[{"content":t}]}}` (`zh` maps to `cmn`) | `speechmatics-enhanced` (not sent) | in config | `additional_vocab` | `$.job.status=="done"` then plain-text body | 30 s/req, 300 s total |
| **Cartesia** | streaming only (`wss://api.cartesia.ai/stt/turns/websocket`), batch throws `unsupportedProvider` | `X-API-Key` + `Cartesia-Version` | - | `ink-2` (English only) | - | - | - | - |
| **Custom (OpenAI-compatible)** | user-supplied FULL URL (e.g. `https://api.openai.com/v1/audio/transcriptions`) | `Bearer` | multipart: `file`, `model`, `response_format=json`, `temperature=0`, [`language`] | user-typed | `language` | not sent | `$.text` (strict decode, otherwise `.noTranscriptionReturned`) | URLSession default (60 s), no retry |

Not cloud: `Transcription/TranscribeCpp/Cohere/CohereTranscriptionService.swift` is a **local** transcribe.cpp model (the provider was renamed from `"Cohere"` to `.transcribeCpp`). OpenAI has **no** dedicated cloud STT provider. `openAIAPIKey` exists only for AI enhancement, and OpenAI STT is reachable through Custom only.

**Key verification endpoints (all GET, 10 s):**
Groq `https://api.groq.com/openai/v1/models` (Bearer) | Gemini `https://generativelanguage.googleapis.com/v1beta/models` (x-goog-api-key) |
ElevenLabs `https://api.elevenlabs.io/v1/user` (xi-api-key) | Deepgram `https://api.deepgram.com/v1/projects` (Token) |
Mistral `https://api.mistral.ai/v1/models` (Bearer) | xAI `https://api.x.ai/v1/api-key` (Bearer) | AssemblyAI `https://api.assemblyai.com/v2/transcript` (raw key) |
Soniox `https://api.soniox.com/v1/files` (Bearer) | Speechmatics `https://asr.api.speechmatics.com/v2/jobs` (Bearer) | Cartesia `https://api.cartesia.ai/voices?limit=1` (X-API-Key + Cartesia-Version).
Custom: POST 1 KB of zero bytes as `probe.wav` + `model`, 15 s timeout. 200/400/415/422 = OK (the server authenticates before it validates audio), 401/403 = bad key, 404 = bad URL. Only HTTPS is accepted, and plain HTTP only for localhost/127.0.0.1/::1.

**Console URLs for "get key" links:** groq `https://console.groq.com/keys`, gemini `https://aistudio.google.com/app/apikey`, elevenlabs `https://elevenlabs.io/app/settings/api-keys`, deepgram `https://console.deepgram.com/project/keys`, openai `https://platform.openai.com/api-keys`, mistral `https://console.mistral.ai/api-keys/`, soniox `https://console.soniox.com/api-keys`.

### 3.4 Known bugs / gotchas found in the old code (fix in the rewrite)
1. **Default language is `"en"`** (`AppDefaults.swift:40`). For a Polish user, every provider that honours the language param transcribes Polish as English. Default the new app to `"pl"`.
2. **Deepgram with "auto"** sends no `language`, and Deepgram then defaults to English (no auto-detect). Use `language=pl`, or `language=multi` for nova-3, or `detect_language=true`.
3. **Vocabulary silently ignored** for Groq, Gemini, Mistral, xAI and Deepgram. Groq/Whisper accepts `prompt` (about 224 tokens), and a comma-joined list of dictionary words there biases spelling. For Gemini, put the words and the language into the text instruction.
4. **Gemini prompt is language-agnostic** (`"Please transcribe this audio file. Provide only the transcribed text."`) and has no `generationConfig`. On 2.5 Flash/Flash-Lite, thinking is on by default and adds latency. Send `generationConfig: {temperature: 0, thinkingConfig: {thinkingBudget: 0}}` (2.5 Flash/Lite; Pro cannot disable thinking; Gemini 3 uses `thinkingLevel` instead, so check the current docs).
5. **Gemini response parsing** takes only `parts[0].text` and decodes `candidates` as non-optional. A safety block or a missing `content` gives a `decodingError` instead of a clear message. Join all `parts[].text` where `thought != true`, and treat a missing candidate as "no result" + `promptFeedback.blockReason`.
6. **Gemini model list** (`GeminiProvider.swift`) contains ids like `gemini-3.7-flash-nano-preview`, `gemini-3.6-flash` and the retired `gemini-1.5-*`. Do not hard-code a long list. Either keep 1-2 known-good ids or build the list from the verify response (`GET /v1beta/models`, keep entries whose `supportedGenerationMethods` contains `generateContent` and whose name contains `flash`).
7. **Soniox** uploads a file and creates a transcription job every time and never DELETEs them (`/v1/files/{id}`, `/v1/transcriptions/{id}`), so account storage fills up.
8. **AssemblyAI `universal-3-5-pro`** has no Polish in its language list, so only `universal-2` works for `pl`.
9. Mistral batch sends no `language` even though the API supports it.
10. `CloudModel.id = UUID()` is regenerated on every launch. Persist the selection by `(provider, modelName)`, never by id.

### 3.5 API key storage (Keychain)
- `KeychainService`: `kSecClassGenericPassword`, **service `"pl.kawalec.VocaType"`**, account = the key identifier, `kSecUseDataProtectionKeychain: true`, and for API keys `kSecAttrSynchronizable: true` (iCloud Keychain). There is no explicit accessibility for API keys (license items use `AfterFirstUnlockThisDeviceOnly`, non-syncable).
- Save = `SecItemUpdate`. On `errSecItemNotFound` it does `SecItemAdd`, and on `errSecDuplicateItem` (race) it retries the update.
- Account naming (`APIKeyManager.providerToKeychainKey`, lookup lowercases the provider key; the fallback is `"<lowercased>APIKey"`):
  `groqAPIKey, geminiAPIKey, elevenLabsAPIKey, deepgramAPIKey, mistralAPIKey, sonioxAPIKey, speechmaticsAPIKey, assemblyAIAPIKey, xaiAPIKey, cartesiaAPIKey, openAIAPIKey, anthropicAPIKey, openRouterAPIKey, cerebrasAPIKey`.
  Custom STT model: `customModel_<UUID>_APIKey`. Custom AI provider: `customAIProvider_<UUID>_APIKey`.
- Entitlements: the signed build has `keychain-access-groups = $(AppIdentifierPrefix)com.prakashjoshipax.VoiceInk` (team `V6J6A3VWY2`). The data-protection keychain + synchronizable **require** a signed build with an access group. The local ad-hoc build (`VoiceInk.local.entitlements`, empty `DEVELOPMENT_TEAM`) has no access group, so Keychain calls will fail (`errSecMissingEntitlement`, -34018) and the code has no fallback.
- **Migration of existing keys:** the new app can read the old items only if it is signed by the same team, lists the same access group (`V6J6A3VWY2.com.prakashjoshipax.VoiceInk`) and queries service `pl.kawalec.VocaType` + the same account + `kSecAttrSynchronizable: true`. Otherwise the user re-enters the keys (there are only 1-2 keys, so re-entry is acceptable).
- Verify-then-save order (all 3 UI flows): trim, call `verifyAPIKey`, save only if valid, refresh usable models, and clear the text field. The onboarding flow also ignores a verify result if the user switched provider meanwhile (`guard selectedProvider?.providerKey == providerKey`).

### 3.6 Errors surfaced to the user (`CloudTranscriptionError`)
`missingAPIKey`, `invalidAPIKey`, `audioFileNotFound`, `apiRequestFailed(status, rawBody)`, `networkError(Error)`, `noTranscriptionReturned`, `dataEncodingError`, `unsupportedProvider`. LLMkit `timeout`/`invalidURL`/`decodingError` all collapse into `networkError`. For the rewrite: map 401/403 to "invalid key", 429 to "rate limited", 413 to "file too large", timeout to "timeout", and keep the raw body for logs only.

## 4. Code excerpts worth copying the idea of

Retry + ephemeral session (LLMkit `HTTPClient.swift`):
```swift
private let retryableStatusCodes: Set<Int> = [429, 500, 502, 503, 504]
func performUpload(_ request: URLRequest, data bodyData: Data, timeout: TimeInterval = 30, maxRetries: Int = 2) async throws -> (Data, URLResponse) {
    var req = request; req.timeoutInterval = timeout
    var lastError: (any Error)?
    for attempt in 0...maxRetries {
        if attempt > 0 { try await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt - 1)) * 1_000_000_000)) }
        let session = makeEphemeralURLSession(timeout: timeout)      // new session each attempt (HTTP/3 + VPN workaround)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.upload(for: req, from: bodyData)
            if let http = response as? HTTPURLResponse, retryableStatusCodes.contains(http.statusCode), attempt < maxRetries {
                lastError = LLMKitError.httpError(statusCode: http.statusCode, message: String(data: data, encoding: .utf8) ?? "")
                continue
            }
            return (data, response)
        } catch let error as NSError where error.domain == NSURLErrorDomain && error.code == NSURLErrorTimedOut {
            throw LLMKitError.timeout                                  // timeouts are NOT retried
        } catch { lastError = error; if attempt < maxRetries { continue } }
    }
    throw lastError ?? LLMKitError.networkError("Request failed after \(maxRetries + 1) attempts")
}
private func makeEphemeralURLSession(timeout: TimeInterval) -> URLSession {
    let c = URLSessionConfiguration.ephemeral
    c.timeoutIntervalForRequest = timeout; c.timeoutIntervalForResource = timeout
    c.requestCachePolicy = .reloadIgnoringLocalCacheData; c.urlCache = nil
    return URLSession(configuration: c)
}
```

Multipart builder (CRLF everywhere, closing boundary appended once):
```swift
mutating func addField(name: String, value: String) {
    body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
    body.append(value.data(using: .utf8)!); body.append("\r\n".data(using: .utf8)!)
}
mutating func addFile(name: String, fileName: String, mimeType: String, fileData: Data) {
    body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(fileName)\"\r\nContent-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
    body.append(fileData); body.append("\r\n".data(using: .utf8)!)
}
var data: Data { var r = body; r.append("--\(boundary)--\r\n".data(using: .utf8)!); return r }
// Content-Type: "multipart/form-data; boundary=\(boundary)", boundary = "Boundary-\(UUID().uuidString)"
```

Gemini request JSON as sent today (improve per 3.4 #4/#5):
```json
{ "contents": [ { "parts": [
    { "text": "Please transcribe this audio file. Provide only the transcribed text." },
    { "inlineData": { "mimeType": "audio/wav", "data": "<base64 wav>" } }
] } ] }
```
Suggested replacement for the text part: `"Transcribe this audio verbatim in Polish (pl). Output only the transcript, no comments. Spell these terms exactly: A, B, C."` plus `"generationConfig": {"temperature": 0, "thinkingConfig": {"thinkingBudget": 0}}`.

Keychain query (keep the same service/account for migration):
```swift
var query: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "pl.kawalec.VocaType",
    kSecAttrAccount as String: "groqAPIKey",            // see naming table in 3.5
    kSecUseDataProtectionKeychain as String: true,
]
if syncable { query[kSecAttrSynchronizable as String] = kCFBooleanTrue }
```

## 5. Recommendation: which providers to keep

Keep **3 built-in providers + 1 generic endpoint**:

1. **Groq, `whisper-large-v3-turbo`** (optionally also `whisper-large-v3`, slower but a bit more accurate on Polish). This is the fastest batch STT available (typically well under 1 s for a dictation clip), it is cheap, Polish is good, and the user already has a Groq key. It is OpenAI-compatible, so it costs almost nothing to implement. Send `language=pl` and `prompt=<vocabulary>`.
2. **Gemini (a current Flash / Flash-Lite id)**. The user already tried it in onboarding, Polish quality is very strong, the prompt carries the dictionary and language, and the same key can drive optional AI cleanup. Disable thinking for latency and cap uploads at about 7 min inline.
3. **ElevenLabs `scribe_v2`**. It has the best accuracy for Polish among the current providers, native `keyterms` for the dictionary, a single synchronous request, and a realtime WebSocket if cloud streaming is ever wanted.
4. **Custom OpenAI-compatible endpoint** (one URL + key + model field). It covers OpenAI `gpt-4o-transcribe`/`whisper-1`, Mistral Voxtral, and self-hosted servers without adding more provider code.

Optional 5th, only if cloud *realtime* is needed: **Deepgram `nova-3`** (lowest-latency streaming, `language=pl` or `multi`). Drop AssemblyAI, Soniox, Speechmatics (polling makes them slower for dictation, and U-3.5 has no Polish), Cartesia (English only), xAI and Mistral native (these two are reachable via Custom if ever needed).

## 6. Minimal design for the rewrite

- `enum CloudSTTProvider: String, Codable, CaseIterable { case groq, gemini, elevenLabs, openAICompatible }`, with static `displayName`, `defaultModel`, `models: [String]`, `keychainAccount` (`groqAPIKey`/`geminiAPIKey`/`elevenLabsAPIKey`/`customSTTAPIKey`) and `consoleURL`.
- `struct STTRequest: Sendable { audio: Data; fileName: String; mimeType = "audio/wav"; model: String; language: String? /* "pl" default */; vocabulary: [String] }`.
- `protocol STTClient: Sendable { func transcribe(_ r: STTRequest, key: String) async throws -> String; func verify(key: String) async throws }`, with one small struct per provider (about 40-60 lines each). `OpenAICompatibleClient(baseURL:)` serves both Groq and Custom.
- `enum HTTP` helper: `upload(_:body:timeout:)` with the ephemeral-session + 2-retry policy from section 4, a `Multipart` builder, and `STTError` mapping (unauthorized, rateLimited, tooLarge, timeout, server(status, body), emptyResult).
- Timeout scales with audio: `max(20, 10 + audioSeconds * 0.5)` for the upload, 10 s for verify. Timeouts are not retried.
- `KeyStore` (Keychain): same service `pl.kawalec.VocaType` and account names, so a signed build with the old access group can migrate keys. On `-34018` fall back to the login keychain (drop `kSecUseDataProtectionKeychain`/sync) so ad-hoc dev builds work.
- Settings stores a single `selectedCloudProvider` + `selectedCloudModel` (+ `customEndpointURL` for Custom) in UserDefaults. Picking a provider is a one-time choice: paste key, Verify, Save.
- `CloudTranscriber.transcribe(wavURL:)`: read the file, build `STTRequest` (language from settings, vocabulary from the dictionary store, deduped case-insensitively), call the client, trim the result, and throw `emptyResult` on empty. Run off the main actor. The caller shows errors in the widget.
- Keep providers stateless `struct`s (Sendable) and do not introduce SwiftData dependencies into the network layer. Vocabulary is passed in.
- Tests: `URLProtocol` stub to assert the multipart field order (xAI-style file-last is not needed for the kept providers), headers, and JSON decoding of fixture responses for each provider, plus a verify-status mapping test.

## 7. Streaming endpoints (for reference only, separate subsystem)
All take PCM s16le 16 kHz mono over WebSocket: Deepgram `wss://api.deepgram.com/v1/listen?encoding=linear16&sample_rate=16000` (Token), ElevenLabs `wss://api.elevenlabs.io/v1/speech-to-text/realtime` (xi-api-key), Mistral `wss://api.mistral.ai/v1/audio/transcriptions/realtime` (Bearer), Soniox `wss://stt-rt.soniox.com/transcribe-websocket` (api_key in the first JSON message), AssemblyAI `wss://streaming.assemblyai.com/v3/ws?sample_rate=16000&encoding=pcm_s16le` (raw key), Speechmatics `wss://eu2.rt.speechmatics.com/v2` (Bearer), Cartesia `wss://api.cartesia.ai/stt/turns/websocket?encoding=pcm_s16le&sample_rate=16000`, xAI (see `XAIStreamingClient.swift`). Sources are in LLMkit `Sources/LLMkit/Streaming/`.
