import Foundation

func testCPUMath() {
    // First sample: no baseline yet, report zero.
    let first = CPUMath.usage(prev: nil, current: .init(user: 100, system: 50, idle: 900, nice: 0))
    T.expect(first.didReset, "cpu first sample resets")
    T.eq(first.busy, 0, "cpu first busy 0")

    // Half busy: 100 busy ticks against 100 idle ticks.
    let half = CPUMath.usage(prev: .init(user: 0, system: 0, idle: 0, nice: 0),
                             current: .init(user: 100, system: 0, idle: 100, nice: 0))
    T.eq(half.busy, 0.5, "cpu 50%")
    T.expect(!half.didReset, "cpu normal not reset")

    // Fully idle and fully busy.
    T.eq(CPUMath.usage(prev: .init(user: 0, system: 0, idle: 0, nice: 0),
                       current: .init(user: 0, system: 0, idle: 200, nice: 0)).busy, 0, "cpu all idle")
    T.eq(CPUMath.usage(prev: .init(user: 0, system: 0, idle: 0, nice: 0),
                       current: .init(user: 200, system: 0, idle: 0, nice: 0)).busy, 1, "cpu all busy")

    // nice counts as busy, and system does too.
    T.eq(CPUMath.usage(prev: .init(user: 0, system: 0, idle: 0, nice: 0),
                       current: .init(user: 0, system: 0, idle: 100, nice: 100)).busy, 0.5, "cpu nice is busy")
    T.eq(CPUMath.usage(prev: .init(user: 0, system: 0, idle: 0, nice: 0),
                       current: .init(user: 25, system: 25, idle: 50, nice: 0)).busy, 0.5, "cpu system is busy")

    // UInt32 wraparound (~50 days of uptime). Fails loudly if someone writes `-`
    // instead of `&-`: user delta must be 14, idle 14 -> 0.5, not a huge number.
    let wrapped = CPUMath.usage(prev: .init(user: 0xFFFF_FFF6, system: 0, idle: 0, nice: 0),
                                current: .init(user: 4, system: 0, idle: 14, nice: 0))
    T.eq(wrapped.busy, 0.5, "cpu survives UInt32 wraparound")
    T.expect(!wrapped.didReset, "cpu wraparound is not a reset")

    // Identical samples: no ticks elapsed, nothing to report.
    let idle = CPUMath.usage(prev: .init(user: 10, system: 10, idle: 10, nice: 10),
                             current: .init(user: 10, system: 10, idle: 10, nice: 10))
    T.expect(idle.didReset, "cpu zero delta resets")
    T.eq(idle.busy, 0, "cpu zero delta busy 0")

    // Always within 0...1.
    let odd = CPUMath.usage(prev: .init(user: 5, system: 5, idle: 5, nice: 5),
                            current: .init(user: 999, system: 1, idle: 7, nice: 3))
    T.expect(odd.busy >= 0 && odd.busy <= 1, "cpu busy stays in 0...1")
}
