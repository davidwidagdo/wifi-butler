import Foundation

func testMemoryMath() {
    // Fixture captured from this machine (16 GiB, Apple Silicon, 16 KiB pages).
    let pages = MemoryMath.Pages(internalPages: 226_912, purgeable: 6_899, wired: 154_071,
                                 compressed: 295_375, external: 213_867, free: 117_041)
    let pageSize: UInt64 = 16_384
    let total: UInt64 = 17_179_869_184

    let r = MemoryMath.compute(pages: pages, pageSize: pageSize, total: total, pressureRaw: 1)

    // App memory = internal - purgeable.
    T.eq(r.app, UInt64(220_013) * pageSize, "mem app = internal - purgeable")
    // Activity Monitor's "Memory Used" = app + wired + compressed.
    T.eq(r.used, UInt64(669_459) * pageSize, "mem used matches Activity Monitor")
    T.eq(r.used, 10_968_416_256, "mem used in bytes")   // 669_459 pages x 16 KiB ~= 10.97 GB
    // Cached files = external + purgeable.
    T.eq(r.cached, UInt64(220_766) * pageSize, "mem cached = external + purgeable")
    T.expect(r.usedFraction > 0.63 && r.usedFraction < 0.65, "mem used fraction ~0.638")

    // Transient sample where purgeable exceeds internal must clamp, not trap.
    // Without a guard this crashes on UInt64 underflow in an -O build.
    let odd = MemoryMath.compute(
        pages: MemoryMath.Pages(internalPages: 10, purgeable: 99, wired: 5,
                                compressed: 5, external: 0, free: 0),
        pageSize: pageSize, total: total, pressureRaw: 1)
    T.eq(odd.app, UInt64(0), "mem app clamps when purgeable > internal")

    // Page size must be honored — the regression test for hardcoding 4096.
    let small = MemoryMath.compute(pages: pages, pageSize: 4_096, total: total, pressureRaw: 1)
    T.eq(small.used, r.used / 4, "mem honors page size (4096 = quarter of 16384)")

    // Divide-by-zero guard.
    T.eq(MemoryMath.compute(pages: pages, pageSize: pageSize, total: 0, pressureRaw: 1).usedFraction,
         0, "mem zero total -> fraction 0")

    // Kernel pressure levels: 1 normal, 2 warning, 4 critical; anything else normal.
    T.expect(MemoryMath.pressure(from: 1) == .normal, "pressure 1 normal")
    T.expect(MemoryMath.pressure(from: 2) == .warning, "pressure 2 warning")
    T.expect(MemoryMath.pressure(from: 4) == .critical, "pressure 4 critical")
    T.expect(MemoryMath.pressure(from: 0) == .normal, "pressure 0 -> normal")
    T.expect(MemoryMath.pressure(from: 99) == .normal, "pressure unknown -> normal")
}
