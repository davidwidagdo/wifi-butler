import Foundation

// Pure disk-capacity arithmetic.
enum DiskMath {
    struct Capacity: Equatable {
        let total: UInt64
        let free: UInt64

        // Always total - free. On an APFS container the boot volume's own used
        // blocks describe only the sealed system snapshot (~10%), not what the
        // user actually occupies (~76%) — deriving it this way avoids that trap.
        var used: UInt64 { total >= free ? total - free : 0 }

        var usedFraction: Double {
            guard total > 0, free <= total else { return 0 }
            return Double(used) / Double(total)
        }
    }
}
