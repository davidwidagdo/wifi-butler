import Foundation

// Pure memory computation from vm_statistics64 page counts. "Used" follows
// Activity Monitor exactly (app + wired + compressed) rather than the misleading
// "free RAM", which macOS keeps low on purpose by caching.
enum MemoryMath {
    struct Pages {
        let internalPages: UInt64   // anonymous
        let purgeable: UInt64
        let wired: UInt64
        let compressed: UInt64      // pages occupied by the compressor
        let external: UInt64        // file-backed
        let free: UInt64
    }

    // The kernel's own memorystatus level — the same signal that drives
    // DISPATCH_SOURCE_TYPE_MEMORYPRESSURE and Activity Monitor's pressure graph.
    enum Pressure: Int32 {
        case normal = 1
        case warning = 2
        case critical = 4
    }

    struct Result {
        let app: UInt64
        let wired: UInt64
        let compressed: UInt64
        let used: UInt64
        let cached: UInt64
        let free: UInt64
        let total: UInt64
        let usedFraction: Double
        let pressure: Pressure
    }

    static func pressure(from raw: Int32) -> Pressure {
        Pressure(rawValue: raw) ?? .normal
    }

    static func compute(pages: Pages, pageSize: UInt64, total: UInt64, pressureRaw: Int32) -> Result {
        // A transient sample can report more purgeable than internal pages;
        // plain subtraction would trap on UInt64 underflow in an -O build.
        let appPages = pages.internalPages >= pages.purgeable
            ? pages.internalPages - pages.purgeable
            : 0

        let app = appPages &* pageSize
        let wired = pages.wired &* pageSize
        let compressed = pages.compressed &* pageSize
        let used = app &+ wired &+ compressed
        let cached = (pages.external &+ pages.purgeable) &* pageSize
        let free = pages.free &* pageSize

        return Result(app: app, wired: wired, compressed: compressed,
                      used: used, cached: cached, free: free, total: total,
                      usedFraction: total > 0 ? Double(used) / Double(total) : 0,
                      pressure: pressure(from: pressureRaw))
    }
}
