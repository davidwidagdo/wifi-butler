import Foundation

func testProcessMath() {
    // Ranking is by DELTA, not by absolute CPU time: pid 1 has a bigger lifetime
    // total but pid 2 is the one busy right now... except here pid 1 also has the
    // bigger delta, so it wins.
    let top = ProcessMath.topCPU(prev: [1: 1_000, 2: 0],
                                 current: [1: 1_100, 2: 50],
                                 elapsedMach: 1_000, limit: 3)
    T.eq(top.first?.pid ?? 0, Int32(1), "cpu ranked by delta")
    T.eq(top.count, 2, "cpu returns both known pids")

    // Normalization: a delta equal to half the elapsed window is half a core.
    T.eq(ProcessMath.topCPU(prev: [7: 0], current: [7: 500],
                            elapsedMach: 1_000, limit: 3).first?.value ?? -1,
         0.5, "cpu delta normalizes to fraction of one core")
    // Multi-core: more CPU time than wall time is legal (Activity Monitor style).
    T.eq(ProcessMath.topCPU(prev: [7: 0], current: [7: 2_000],
                            elapsedMach: 1_000, limit: 3).first?.value ?? -1,
         2.0, "cpu can exceed one core")

    // A process that appeared after the baseline has no delta — exclude it.
    T.expect(ProcessMath.topCPU(prev: [:], current: [9: 500], elapsedMach: 1_000, limit: 3).isEmpty,
             "cpu skips pids without a baseline")
    // pid reuse / counter went backwards — exclude, never underflow.
    T.expect(ProcessMath.topCPU(prev: [9: 900], current: [9: 100], elapsedMach: 1_000, limit: 3).isEmpty,
             "cpu skips backwards counters")
    // Degenerate window.
    T.expect(ProcessMath.topCPU(prev: [9: 0], current: [9: 100], elapsedMach: 0, limit: 3).isEmpty,
             "cpu zero elapsed -> empty")

    // limit is respected.
    var many: [Int32: UInt64] = [:], base: [Int32: UInt64] = [:]
    for i in Int32(1)...Int32(10) { base[i] = 0; many[i] = UInt64(i) * 100 }
    T.eq(ProcessMath.topCPU(prev: base, current: many, elapsedMach: 1_000, limit: 3).count,
         3, "cpu respects limit")

    // Deterministic tie-break: equal values sort by lower pid, so the menu doesn't
    // reshuffle between samples.
    let tied = ProcessMath.topCPU(prev: [5: 0, 2: 0, 8: 0],
                                  current: [5: 100, 2: 100, 8: 100],
                                  elapsedMach: 1_000, limit: 3)
    T.eq(tied.map { $0.pid }, [Int32(2), Int32(5), Int32(8)], "cpu tie-break by pid")

    // RSS ranking: plain descending sort with the same tie-break.
    let rss = ProcessMath.topRSS([(pid: 1, rss: 100), (pid: 2, rss: 300), (pid: 3, rss: 200)], limit: 2)
    T.eq(rss.map { $0.pid }, [Int32(2), Int32(3)], "rss sorts descending")
    T.eq(rss.count, 2, "rss respects limit")

    // Aggregation by app name collapses Electron/Chrome helper swarms into one row
    // and keeps the lowest pid as the representative.
    let agg = ProcessMath.aggregate([
        .init(pid: 30, name: "Google Chrome Helper", value: 10),
        .init(pid: 12, name: "Google Chrome Helper", value: 20),
        .init(pid: 40, name: "Xcode", value: 25),
        .init(pid: 55, name: "Google Chrome Helper", value: 15),
    ], limit: 3)
    T.eq(agg.count, 2, "aggregate collapses same-name rows")
    T.eq(agg.first?.name ?? "", "Google Chrome Helper", "aggregate sums to the top")
    T.eq(agg.first?.value ?? 0, 45, "aggregate sums values")
    T.eq(agg.first?.count ?? 0, 3, "aggregate counts members")
    T.eq(agg.first?.pid ?? 0, Int32(12), "aggregate keeps lowest pid")
    T.eq(agg.last?.count ?? 0, 1, "aggregate single member count is 1")
}
