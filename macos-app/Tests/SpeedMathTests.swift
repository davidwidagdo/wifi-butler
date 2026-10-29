import Foundation

func testSpeedMath() {
    let first = SpeedMath.compute(prev: nil, current: (100, 50), elapsed: 1)
    T.expect(first.didReset, "first sample resets")
    T.eq(first.down, 0, "first down 0")
    T.eq(first.rxDelta, UInt64(0), "first rx delta 0")

    let norm = SpeedMath.compute(prev: (100, 50), current: (1100, 550), elapsed: 1)
    T.eq(norm.down, 1000, "down rate")
    T.eq(norm.up, 500, "up rate")
    T.eq(norm.rxDelta, UInt64(1000), "rx delta")
    T.eq(norm.txDelta, UInt64(500), "tx delta")
    T.expect(!norm.didReset, "normal not reset")

    let half = SpeedMath.compute(prev: (0, 0), current: (1000, 500), elapsed: 2)
    T.eq(half.down, 500, "down over 2s")
    T.eq(half.up, 250, "up over 2s")

    let reset = SpeedMath.compute(prev: (1000, 500), current: (10, 5), elapsed: 1)
    T.expect(reset.didReset, "backward counter is a reset")
    T.eq(reset.down, 0, "reset down 0")

    let zeroT = SpeedMath.compute(prev: (0, 0), current: (100, 100), elapsed: 0)
    T.expect(zeroT.didReset, "zero elapsed guarded")
}
