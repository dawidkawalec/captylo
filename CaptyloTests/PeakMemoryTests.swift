import Foundation
import Testing
@testable import Captylo

struct PeakMemoryTests {
    @Test func reportsAFootprintAndItsPeak() {
        let footprint = PeakMemory.footprint()
        #expect(footprint != nil)
        guard let footprint else { return }
        // A test host always has a few MB resident; the peak can never be below the current value.
        #expect(footprint.currentBytes > 1_000_000)
        #expect(footprint.peakBytes >= footprint.currentBytes)
        #expect(PeakMemory.currentMB() >= 1)
        #expect(PeakMemory.peakMB() >= PeakMemory.currentMB())
    }

    @Test func megabytesRoundToWholeNumbers() {
        #expect(PeakMemory.megabytes(0) == 0)
        #expect(PeakMemory.megabytes(1_048_576) == 1)
        #expect(PeakMemory.megabytes(1_572_864) == 2)
        #expect(PeakMemory.megabytes(629_145_600) == 600)
    }
}
