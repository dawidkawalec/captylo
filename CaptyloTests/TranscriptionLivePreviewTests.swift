import Foundation
import Testing
@testable import Captylo

struct TranscriptionLivePreviewTests {
    private static let tick: Duration = .milliseconds(20)

    /// Returns the first value or nil when the stream ends or `limit` passes.
    private func first(of stream: AsyncStream<String>, within limit: Duration = .seconds(3)) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            group.addTask {
                for await text in stream { return text }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: limit)
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    @Test func yieldsPreviewTextForEnoughAudio() async {
        let engine = TranscriptionFakeLocalTranscriber(text: "cześć")
        let buffer = SampleBuffer()
        buffer.append([Float](repeating: 0.1, count: 16_000))
        let preview = LivePreview(engine: engine, tick: Self.tick)

        let text = await first(of: preview.updates(buffer: buffer, language: "pl"))

        #expect(text == "cześć")
        #expect(engine.previewCalls >= 1)
    }

    @Test func waitsForNewSamplesBeforeThePass() async throws {
        let engine = TranscriptionFakeLocalTranscriber(text: "cześć")
        let buffer = SampleBuffer()
        buffer.append([Float](repeating: 0.1, count: 4_000))
        let preview = LivePreview(engine: engine, tick: Self.tick)
        let stream = preview.updates(buffer: buffer, language: nil)

        let consumer = Task { () -> String? in
            for await text in stream { return text }
            return nil
        }
        try await Task.sleep(for: .milliseconds(150))
        #expect(engine.previewCalls == 0)

        buffer.append([Float](repeating: 0.1, count: 8_000))
        #expect(await consumer.value == "cześć")
    }

    @Test func stopsWhenTheConsumerIsCancelled() async throws {
        let engine = TranscriptionFakeLocalTranscriber(text: "cześć")
        let buffer = SampleBuffer()
        buffer.append([Float](repeating: 0.1, count: 16_000))
        let preview = LivePreview(engine: engine, tick: Self.tick)
        let stream = preview.updates(buffer: buffer, language: "pl")

        let consumer = Task {
            var received = 0
            for await _ in stream {
                received += 1
                buffer.append([Float](repeating: 0.1, count: 8_000))
            }
            return received
        }
        try await Task.sleep(for: .milliseconds(150))
        consumer.cancel()
        let received = await consumer.value
        #expect(received >= 1)

        try await Task.sleep(for: .milliseconds(100))
        let callsAfterCancel = engine.previewCalls
        buffer.append([Float](repeating: 0.1, count: 8_000))
        try await Task.sleep(for: .milliseconds(150))
        #expect(engine.previewCalls == callsAfterCancel)
    }

    @Test func skipsEmptyResultsAndKeepsRunningAfterErrors() async throws {
        let engine = TranscriptionFakeLocalTranscriber(text: "", failure: .modelNotReady)
        let buffer = SampleBuffer()
        buffer.append([Float](repeating: 0.1, count: 16_000))
        let preview = LivePreview(engine: engine, tick: Self.tick)

        let text = await first(of: preview.updates(buffer: buffer, language: "pl"), within: .milliseconds(200))

        #expect(text == nil)
        #expect(engine.previewCalls >= 1)
    }
}
