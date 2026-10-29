import Foundation

// Pure CPU-usage computation from the kernel's cumulative tick counters. Kept
// separate from the mach calls so it can be unit-tested (see SpeedMath for the
// same split).
enum CPUMath {
    // Aggregate ticks across all cores, as reported by HOST_CPU_LOAD_INFO. These
    // are natural_t (UInt32) and increment at roughly ncpu * 100 Hz, so idle wraps
    // in about 50 days of uptime — which a login item will reach.
    struct Ticks: Equatable {
        let user: UInt32
        let system: UInt32
        let idle: UInt32
        let nice: UInt32
    }

    struct Result {
        let busy: Double     // 0...1 across the whole machine
        let didReset: Bool   // first sample, or no ticks elapsed
    }

    // Self-normalizing: the tick totals carry their own time base, so unlike
    // SpeedMath this needs no `elapsed` parameter.
    static func usage(prev: Ticks?, current: Ticks) -> Result {
        guard let prev = prev else {
            return Result(busy: 0, didReset: true)
        }
        // Wrapping subtraction is exactly right here: UInt32 counters that have
        // rolled over still give the correct delta for any interval under ~49
        // days. (SpeedMath deliberately differs — its 64-bit counters can only go
        // backwards on a real reset.)
        let dUser = UInt64(current.user &- prev.user)
        let dSystem = UInt64(current.system &- prev.system)
        let dIdle = UInt64(current.idle &- prev.idle)
        let dNice = UInt64(current.nice &- prev.nice)

        let busy = dUser &+ dSystem &+ dNice
        let total = busy &+ dIdle
        guard total > 0 else { return Result(busy: 0, didReset: true) }
        return Result(busy: min(1, Double(busy) / Double(total)), didReset: false)
    }
}
