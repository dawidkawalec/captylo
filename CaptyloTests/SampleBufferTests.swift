import Testing
@testable import Captylo

struct SampleBufferTests {
    @Test func appendsArraysAndPointers() {
        let buffer = SampleBuffer(reservingCapacity: 16)
        buffer.append([0.1, 0.2, 0.3])
        let extra: [Float] = [0.4, 0.5]
        extra.withUnsafeBufferPointer { buffer.append($0) }

        #expect(buffer.count == 5)
        #expect(buffer.snapshot() == [0.1, 0.2, 0.3, 0.4, 0.5])
        #expect(!buffer.isEmpty)
    }

    @Test func tailReturnsLastSamplesOrEverything() {
        let buffer = SampleBuffer()
        buffer.append([1, 2, 3, 4, 5])

        #expect(buffer.tail(2) == [4, 5])
        #expect(buffer.tail(10) == [1, 2, 3, 4, 5])
        #expect(buffer.tail(0) == [])
        #expect(buffer.tail(-3) == [])
    }

    @Test func snapshotIsACopy() {
        let buffer = SampleBuffer()
        buffer.append([1, 2])
        let snapshot = buffer.snapshot()
        buffer.append([3])

        #expect(snapshot == [1, 2])
        #expect(buffer.snapshot() == [1, 2, 3])
    }

    @Test func durationFollowsSampleRate() {
        let buffer = SampleBuffer()
        buffer.append([Float](repeating: 0, count: SampleBuffer.sampleRate / 2))
        #expect(buffer.duration == 0.5)
    }

    @Test func removeAllKeepsBufferUsable() {
        let buffer = SampleBuffer()
        buffer.append([1, 2, 3])
        buffer.removeAll()
        #expect(buffer.isEmpty)
        buffer.append([9])
        #expect(buffer.snapshot() == [9])
    }

    @Test func concurrentAppendsAreSerialized() async {
        let buffer = SampleBuffer()
        let writers = 8
        let perWriter = 2_000

        await withTaskGroup(of: Void.self) { group in
            for writer in 0..<writers {
                group.addTask {
                    let chunk = [Float](repeating: Float(writer), count: perWriter)
                    for _ in 0..<4 {
                        chunk.withUnsafeBufferPointer { buffer.append($0) }
                        _ = buffer.tail(100)
                    }
                }
            }
        }

        #expect(buffer.count == writers * perWriter * 4)
    }
}
