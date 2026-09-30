import Foundation

extension FileTranscriptionQueue.Services {
    /// Production wiring: the same router, dictionary and database the dictation path uses,
    /// plus a dedicated `Enhancer` with the 15 s file deadline when AI cleanup is on.
    /// Takes the services one by one so `AppState.init` can build the queue it owns.
    @MainActor
    static func make(
        settings: AppSettings,
        router: any TranscriptionRouting,
        dictionary: DictionaryStore,
        database: Database,
        client: OpenRouterClient,
        keyStore: KeyStore,
        stats: StatsTicker,
        persistsHistory: Bool
    ) -> FileTranscriptionQueue.Services {
        FileTranscriptionQueue.Services(
            router: router,
            engine: { settings.sttEngine },
            language: { settings.transcriptionLanguage },
            vocabulary: { dictionary.data.vocabulary },
            processor: { dictionary.processor },
            enhancement: {
                guard settings.aiEnabled else { return nil }
                let model = settings.aiModel
                // Own session: the dictation LLM session times out after 4 s / 10 s, well
                // before the 15 s file deadline a long transcript needs.
                let enhancer = Enhancer(
                    client: client,
                    keyStore: keyStore,
                    modelProvider: { model },
                    session: HTTP.fileLLMSession,
                    deadline: FileTranscriptionQueue.enhancementDeadline,
                    tokenCap: FileTranscriptionQueue.enhancementTokenCap
                )
                return FileTranscriptionQueue.FileEnhancement(
                    enhancer: enhancer,
                    mode: settings.activeMode,
                    vocabulary: dictionary.data.vocabulary
                )
            },
            save: { record in try await database.upsert(record) },
            didSave: { stats.bump() },
            // The in-memory fallback store loses its rows at quit: keep no WAV for them either.
            saveHistory: { settings.saveHistory && persistsHistory }
        )
    }
}
