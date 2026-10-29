import Foundation

// Pure ranking of per-process samples. Uses Int32 rather than pid_t so the file
// has no Darwin dependency and stays unit-testable.
enum ProcessMath {
    struct Ranked: Equatable {
        let pid: Int32
        let value: Double   // CPU: cores (1.0 == one core saturated). RSS: bytes.
    }

    // One row after grouping by application name.
    struct Named: Equatable {
        let pid: Int32      // lowest pid of the group, as a stable representative
        let name: String
        let value: Double
        var count: Int = 1  // how many processes were merged
    }

    // Ranks by CPU time consumed *since the previous snapshot*, not since launch —
    // a lifetime average would rank long-running daemons above whatever is
    // actually spinning the fan right now.
    //
    // `elapsedMach` and the counter deltas are both in mach absolute units, so the
    // timebase cancels and no mach_timebase_info conversion is needed.
    static func topCPU(prev: [Int32: UInt64], current: [Int32: UInt64],
                       elapsedMach: UInt64, limit: Int) -> [Ranked] {
        guard elapsedMach > 0 else { return [] }
        var out: [Ranked] = []
        out.reserveCapacity(current.count)
        for (pid, now) in current {
            // No baseline (process started after the last sweep), or the counter
            // went backwards (pid reuse) — either way there is no valid delta.
            guard let before = prev[pid], now >= before else { continue }
            let delta = now - before
            guard delta > 0 else { continue }
            out.append(Ranked(pid: pid, value: Double(delta) / Double(elapsedMach)))
        }
        return sortedTop(out, limit: limit)
    }

    static func topRSS(_ current: [(pid: Int32, rss: UInt64)], limit: Int) -> [Ranked] {
        sortedTop(current.map { Ranked(pid: $0.pid, value: Double($0.rss)) }, limit: limit)
    }

    // Collapses processes sharing a name (Chrome/Electron helper swarms would
    // otherwise fill every slot) into one row carrying the summed value.
    static func aggregate(_ rows: [Named], limit: Int) -> [Named] {
        var merged: [String: Named] = [:]
        for row in rows {
            if let existing = merged[row.name] {
                merged[row.name] = Named(pid: min(existing.pid, row.pid),
                                         name: row.name,
                                         value: existing.value + row.value,
                                         count: existing.count + row.count)
            } else {
                merged[row.name] = row
            }
        }
        // Descending by value, ties broken by lowest pid so the menu doesn't
        // reshuffle between samples.
        return Array(merged.values
            .sorted { $0.value == $1.value ? $0.pid < $1.pid : $0.value > $1.value }
            .prefix(limit))
    }

    private static func sortedTop(_ rows: [Ranked], limit: Int) -> [Ranked] {
        Array(rows
            .sorted { $0.value == $1.value ? $0.pid < $1.pid : $0.value > $1.value }
            .prefix(limit))
    }
}
