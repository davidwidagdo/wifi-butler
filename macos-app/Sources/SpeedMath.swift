import Foundation

// Pure, dependency-free speed computation shared by SpeedMonitor. Kept separate
// so it can be unit-tested without the timer, CoreWLAN, or sysctl.
enum SpeedMath {
    struct Result {
        let down: Double      // bytes/sec
        let up: Double        // bytes/sec
        let rxDelta: UInt64   // bytes since last sample (0 on reset/first)
        let txDelta: UInt64
        let didReset: Bool    // counter went backwards, first sample, or bad elapsed
    }

    // `prev == nil` is the first sample: establish a baseline, report zero speed.
    // A counter that went backwards (reconnect/reboot) is a reset: zero this tick.
    static func compute(prev: (rx: UInt64, tx: UInt64)?,
                        current: (rx: UInt64, tx: UInt64),
                        elapsed: Double) -> Result {
        guard let prev = prev else {
            return Result(down: 0, up: 0, rxDelta: 0, txDelta: 0, didReset: true)
        }
        if current.rx < prev.rx || current.tx < prev.tx || elapsed <= 0 {
            return Result(down: 0, up: 0, rxDelta: 0, txDelta: 0, didReset: true)
        }
        let rxD = current.rx - prev.rx
        let txD = current.tx - prev.tx
        return Result(down: Double(rxD) / elapsed,
                      up: Double(txD) / elapsed,
                      rxDelta: rxD, txDelta: txD, didReset: false)
    }
}
