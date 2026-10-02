import Foundation
import os

/// ElevenLabs Scribe (`scribe_v2`) batch client (brief 5.2). Request building is pure so tests
/// can inspect the multipart body; transport errors map to `STTError`.
struct ElevenLabsSTT: Sendable {
    static let transcribeURL = URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!
    static let userURL = URL(string: "https://api.elevenlabs.io/v1/user")!
    static let modelID = STTEngine.elevenLabs.modelName
    static let verifyTimeout: TimeInterval = 10
    static let keytermMaxCount = 1000
    static let keytermMaxLength = 50
    static let keytermMaxWords = 5
    static let keytermForbidden: Set<Character> = ["<", ">", "{", "}", "[", "]", "\\"]

    /// How long a take waits for the Keychain (an ACL prompt after an update) before it gives up.
    static let keyLookupTimeout: Duration = .seconds(3)

    private let session: URLSession
    private let keyProvider: @Sendable () async -> KeyStore.Lookup
    private let makeRetrySession: @Sendable () -> URLSession
    private let deadline: @Sendable (_ audioSeconds: Double) -> TimeInterval

    /// - Parameters:
    ///   - session: shared upload session for the first attempt.
    ///   - keyProvider: looks the API key up at call time without blocking the caller (nil or empty =
    ///     `missingKey`, `.timedOut` = `keychainTimeout`); wire it to `KeyStore.load(_:timeout:)`.
    ///   - retrySession: fresh session for the single retry after a timeout or network error (gotcha 72).
    ///   - deadline: total seconds per attempt for a take of the given length (tests shorten it).
    init(
        session: URLSession = .shared,
        keyProvider: @escaping @Sendable () async -> KeyStore.Lookup,
        retrySession: @escaping @Sendable () -> URLSession = { URLSession(configuration: .ephemeral) },
        deadline: @escaping @Sendable (_ audioSeconds: Double) -> TimeInterval = { ElevenLabsSTT.timeout(forAudioSeconds: $0) }
    ) {
        self.session = session
        self.keyProvider = keyProvider
        self.makeRetrySession = retrySession
        self.deadline = deadline
    }

    // MARK: - Calls

    /// Runs off the caller's actor: the multipart body of a long file is large and must never be
    /// built on the main thread.
    @concurrent
    func transcribe(_ request: STTRequest) async throws -> String {
        try Self.parseText(await upload(request, options: .dictation))
    }

    /// A meeting track: the words with their times (seconds from the start of the file), for
    /// the transcript that replaces the live one. `request.wav` may hold any format Scribe reads
    /// (`options.mimeType`).
    @concurrent
    func transcribeWords(_ request: STTRequest, mimeType: String) async throws -> [Word] {
        try Self.parseWords(await upload(request, options: UploadOptions(mimeType: mimeType, timestamps: "word")))
    }

    /// The key lookup, the upload and one retry on a fresh session after a transport failure;
    /// returns the body of a 2xx answer.
    private func upload(_ request: STTRequest, options: UploadOptions) async throws -> Data {
        let key: String
        switch await keyProvider() {
        case .timedOut:
            Log.transcription.error("ElevenLabs skipped: Keychain read did not finish in time")
            throw STTError.keychainTimeout
        case .value(let value):
            guard let normalized = Self.normalizedKey(value) else { throw STTError.missingKey }
            key = normalized
        }
        try Task.checkCancellation()
        let (urlRequest, body) = Self.makeUpload(request, key: key, options: options)
        let deadline = self.deadline(request.audioSeconds)
        do {
            return try await perform(urlRequest, body: body, on: session, deadline: deadline)
        } catch let error as STTError where error.isTransport && !Task.isCancelled {
            Log.transcription.warning("ElevenLabs upload failed (\(String(describing: error), privacy: .public)), retrying on a fresh session")
            let retry = makeRetrySession()
            defer { retry.finishTasksAndInvalidate() }
            return try await perform(urlRequest, body: body, on: retry, deadline: deadline)
        }
    }

    /// `GET /v1/user`: any 2xx means the key is valid.
    func verify(key: String) async throws {
        guard let key = Self.normalizedKey(key) else { throw STTError.missingKey }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: Self.makeVerifyRequest(key: key))
        } catch {
            throw Self.mapTransportError(error)
        }
        guard let http = response as? HTTPURLResponse else { throw Self.invalidResponse }
        if let failure = Self.mapStatus(http.statusCode, body: data) {
            throw failure
        }
    }

    /// One upload raced against `deadline` seconds (brief 5.2). `URLRequest.timeoutInterval` is only
    /// an idle timeout and the session's resource timeout is a loose cap, so the total deadline is
    /// enforced here; the loser is cancelled.
    private func perform(_ request: URLRequest, body: Data, on session: URLSession, deadline: TimeInterval) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
                group.addTask {
                    try await session.upload(for: request, from: body)
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(deadline))
                    throw STTError.timeout
                }
                defer { group.cancelAll() }
                guard let first = try await group.next() else { throw STTError.timeout }
                return first
            }
        } catch let error as STTError {
            if Task.isCancelled { throw CancellationError() }
            throw error
        } catch {
            // A cancelled take surfaces as `URLError.cancelled`: keep it a cancellation, never a
            // network error that would retry, fall back to the local engine or save a failed row.
            if Self.isCancellation(error) || Task.isCancelled { throw CancellationError() }
            throw Self.mapTransportError(error)
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw Self.invalidResponse }
        if let failure = Self.mapStatus(http.statusCode, body: data) {
            Log.transcription.error("ElevenLabs HTTP \(http.statusCode): \(Self.shortBody(data), privacy: .public)")
            throw failure
        }
        return data
    }

    // MARK: - Request building (pure)

    /// What differs between a dictation take and a meeting track.
    struct UploadOptions: Sendable, Equatable {
        var mimeType = "audio/wav"
        /// `timestamps_granularity`: "none" for dictation, "word" for meetings.
        var timestamps = "none"

        static let dictation = UploadOptions()
    }

    /// Multipart POST with the body in `httpBody` (gotcha 74: CRLF everywhere, closing boundary once).
    static func makeRequest(_ request: STTRequest, key: String, options: UploadOptions = .dictation) -> URLRequest {
        var (urlRequest, body) = makeUpload(request, key: key, options: options)
        urlRequest.httpBody = body
        return urlRequest
    }

    /// The request without a body plus the multipart body, built once, for `upload(for:from:)`.
    static func makeUpload(_ request: STTRequest, key: String, options: UploadOptions = .dictation) -> (URLRequest, Data) {
        let boundary = "Boundary-\(UUID().uuidString)"
        var form = Multipart(boundary: boundary)
        form.addField("model_id", request.model.isEmpty ? modelID : request.model)
        form.addFile(name: "file", fileName: request.fileName, mimeType: options.mimeType, data: request.wav)
        if let language = request.language, !language.isEmpty, language != TranscriptionLanguages.auto {
            form.addField("language_code", language)
        }
        form.addField("tag_audio_events", "false")
        form.addField("temperature", "0.0")
        form.addField("no_verbatim", "true")
        form.addField("timestamps_granularity", options.timestamps)
        for term in keyterms(from: request.vocabulary) {
            form.addField("keyterms", term)
        }

        var urlRequest = URLRequest(url: transcribeURL)
        urlRequest.httpMethod = "POST"
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        urlRequest.timeoutInterval = timeout(forAudioSeconds: request.audioSeconds)
        urlRequest.setValue(key, forHTTPHeaderField: "xi-api-key")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        return (urlRequest, form.encoded())
    }

    static func makeVerifyRequest(key: String) -> URLRequest {
        var urlRequest = URLRequest(url: userURL)
        urlRequest.httpMethod = "GET"
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        urlRequest.timeoutInterval = verifyTimeout
        urlRequest.setValue(key, forHTTPHeaderField: "xi-api-key")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        return urlRequest
    }

    /// Upload deadline: `max(20, 10 + 0.5 * audioSeconds)` seconds.
    static func timeout(forAudioSeconds seconds: Double) -> TimeInterval {
        max(20, 10 + 0.5 * seconds)
    }

    /// Scribe keyterm rules: <= 50 chars, <= 5 words, none of `<>{}[]\`, case-insensitive dedupe, <= 1000.
    static func keyterms(from vocabulary: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in vocabulary {
            let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, term.count <= keytermMaxLength else { continue }
            guard term.split(whereSeparator: \.isWhitespace).count <= keytermMaxWords else { continue }
            guard !term.contains(where: { keytermForbidden.contains($0) }) else { continue }
            guard seen.insert(term.lowercased()).inserted else { continue }
            result.append(term)
            if result.count == keytermMaxCount { break }
        }
        return result
    }

    // MARK: - Response handling (pure)

    static func mapStatus(_ code: Int, body: Data) -> STTError? {
        switch code {
        case 200..<300: return nil
        case 401, 403: return .unauthorized
        case 413: return .tooLarge
        case 429: return .rateLimited
        default: return .server(code, shortBody(body))
        }
    }

    static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        return (error as? URLError)?.code == .cancelled
    }

    static func mapTransportError(_ error: any Error) -> STTError {
        if let urlError = error as? URLError {
            return urlError.code == .timedOut ? .timeout : .network(urlError.localizedDescription)
        }
        return .network(error.localizedDescription)
    }

    /// Reads `$.text`; whitespace-only or missing text is `STTError.empty`.
    static func parseText(_ data: Data) throws -> String {
        struct Response: Decodable {
            let text: String?
        }
        let decoded: Response
        do {
            decoded = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw invalidResponse
        }
        let text = (decoded.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw STTError.empty }
        return text
    }

    /// One recognized word of a `timestamps_granularity=word` answer, times in seconds.
    struct Word: Sendable, Equatable, Decodable {
        var text: String
        var start: Double
        var end: Double
    }

    /// Reads `$.words`, keeping only `"type": "word"` entries (spacing and audio events go).
    /// An answer without words is an empty list: the track may be silent.
    static func parseWords(_ data: Data) throws -> [Word] {
        struct Entry: Decodable {
            let text: String?
            let start: Double?
            let end: Double?
            let type: String?
        }
        struct Response: Decodable {
            let words: [Entry]?
        }
        let decoded: Response
        do {
            decoded = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw invalidResponse
        }
        return (decoded.words ?? []).compactMap { entry in
            guard entry.type == nil || entry.type == "word",
                  let text = entry.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
                  let start = entry.start, let end = entry.end else { return nil }
            return Word(text: text, start: start, end: max(start, end))
        }
    }

    static func shortBody(_ data: Data) -> String {
        String(decoding: data.prefix(200), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static var invalidResponse: STTError {
        .network(String(localized: "Nieprawidłowa odpowiedź serwera."))
    }

    private static func normalizedKey(_ key: String?) -> String? {
        guard let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    // MARK: - Multipart

    /// `multipart/form-data` body builder: CRLF line ends, the closing boundary appended once.
    struct Multipart: Sendable {
        let boundary: String
        private var body = Data()

        init(boundary: String) {
            self.boundary = boundary
        }

        mutating func addField(_ name: String, _ value: String) {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append(value)
            append("\r\n")
        }

        mutating func addFile(name: String, fileName: String, mimeType: String, data: Data) {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(fileName)\"\r\nContent-Type: \(mimeType)\r\n\r\n")
            body.append(data)
            append("\r\n")
        }

        /// Appends the closing boundary in place and hands the buffer over (no copy of the audio).
        consuming func encoded() -> Data {
            append("--\(boundary)--\r\n")
            return body
        }

        private mutating func append(_ string: String) {
            body.append(Data(string.utf8))
        }
    }
}

private extension STTError {
    /// Timeouts and network failures get one retry on a fresh session; HTTP failures do not.
    var isTransport: Bool {
        switch self {
        case .timeout, .network: return true
        default: return false
        }
    }
}
