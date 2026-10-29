import Foundation

// Drives periodic sampling: reads interface counters, computes speed via
// SpeedMath, feeds deltas to UsageStore, and reports the latest speed to a
// callback on the main thread. Runs continuously while the app is up so daily
// usage stays accurate even when the menu-bar meter is hidden.
final class SpeedMonitor {
    struct Sample { let down: Double; let up: Double }

    var onUpdate: ((Sample) -> Void)?

    private let usage: UsageStore
    private var timer: Timer?
    private var last: (rx: UInt64, tx: UInt64)?
    private var lastTime = Date()
    private var flushAccum: TimeInterval = 0

    init(usage: UsageStore = .shared) { self.usage = usage }

    private var interval: TimeInterval { TimeInterval(max(1, Settings.shared.speedInterval)) }

    func start() {
        stop()
        last = nil
        lastTime = Date()
        flushAccum = 0
        tick()   // immediate baseline sample
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = interval * 0.2
        // .common so it keeps firing while the status menu is open.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // Re-read interval/interface after a Settings change.
    func restart() { start() }

    private func tick() {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastTime)
        lastTime = now

        guard let name = NetworkInterface.resolved(override: Settings.shared.wifiInterfaceOverride),
              let current = NetworkStats.counters(for: name) else {
            last = nil
            emit(Sample(down: 0, up: 0))
            return
        }

        let r = SpeedMath.compute(prev: last, current: current, elapsed: elapsed)
        last = current
        if !r.didReset {
            usage.add(rx: r.rxDelta, tx: r.txDelta, downRate: r.down, upRate: r.up)
        }
        emit(Sample(down: r.down, up: r.up))

        // Periodic flush (~ every 10s of wall time) to limit disk writes.
        flushAccum += elapsed
        if flushAccum >= 10 {
            flushAccum = 0
            usage.flush()
        }
    }

    private func emit(_ s: Sample) {
        if Thread.isMainThread { onUpdate?(s) }
        else { DispatchQueue.main.async { [weak self] in self?.onUpdate?(s) } }
    }
}
