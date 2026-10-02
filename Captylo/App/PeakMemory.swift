import Darwin
import Foundation

/// Physical memory footprint of this process, as Activity Monitor's "Memory" column counts it
/// (`task_info` `TASK_VM_INFO`: `phys_footprint` now, `ledger_phys_footprint_peak` since launch).
/// Printed by `--compare-models` and `--meeting-from-files` so long runs can be checked for growth.
enum PeakMemory {
    struct Footprint: Equatable, Sendable {
        let currentBytes: Int
        /// Highest footprint of the process so far (monotonic, never below `currentBytes`).
        let peakBytes: Int
    }

    /// nil only when the kernel refuses the query (never seen in practice).
    static func footprint() -> Footprint? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                task_info(task_self_trap(), task_flavor_t(TASK_VM_INFO), reboundPointer, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let current = Int(info.phys_footprint)
        return Footprint(currentBytes: current, peakBytes: max(current, Int(info.ledger_phys_footprint_peak)))
    }

    /// Current footprint in whole MB (0 when unavailable).
    static func currentMB() -> Int {
        megabytes(footprint()?.currentBytes ?? 0)
    }

    /// Peak footprint since launch in whole MB (0 when unavailable).
    static func peakMB() -> Int {
        megabytes(footprint()?.peakBytes ?? 0)
    }

    /// Bytes to MB (1024 * 1024), rounded to the nearest whole number.
    static func megabytes(_ bytes: Int) -> Int {
        Int((Double(bytes) / 1_048_576).rounded())
    }
}
