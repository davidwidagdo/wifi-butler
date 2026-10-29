import Foundation

// Samples CPU, memory, disk and uptime on a timer and reports them on the main
// thread. Mirrors SpeedMonitor's structure; the divisor pattern matches its
// flushAccum idiom so slow work rides inside the fast loop.
//
// A separate timer from SpeedMonitor on purpose: sharing one would tie the CPU
// sampling window to the speed-meter interval, so changing that setting would
// silently change how much the CPU figure is smoothed.
final class SystemMonitor {
    struct Sample {
        let cpuBusy: Double            // 0...1
        let memory: MemoryMath.Result
        let disk: DiskMath.Capacity?   // nil until the first slow tick
        let uptime: TimeInterval
    }

    var onUpdate: ((Sample) -> Void)?

    private var timer: Timer?
    private var lastTicks: CPUMath.Ticks?
    private var bootDate: Date?
    private var lastDisk: DiskMath.Capacity?
    private var tickCount = 0

    // Disk capacity barely moves; sampling it every tick would be waste.
    private var diskEveryNTicks: Int { max(1, 60 / max(1, Settings.shared.systemInterval)) }

    private var interval: TimeInterval { TimeInterval(max(1, Settings.shared.systemInterval)) }

    func start() {
        stop()
        lastTicks = nil
        lastDisk = nil
        tickCount = 0
        bootDate = SystemStats.bootDate()
        tick()   // immediate baseline
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = interval * 0.2
        // .common so the numbers keep updating while the status menu is open —
        // which is the one moment anybody is reading them.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // Re-read the interval after a settings change, and drop the CPU baseline
    // after a wake (a multi-hour sleep makes the previous delta meaningless).
    func restart() { start() }

    // Force a fresh sample so the dropdown is never stale when it opens.
    func refreshNow() { tick() }

    private func tick() {
        guard let pages = SystemStats.memoryPages() else { return }

        var busy: Double = 0
        if let ticks = SystemStats.cpuTicks() {
            let result = CPUMath.usage(prev: lastTicks, current: ticks)
            lastTicks = ticks
            if !result.didReset { busy = result.busy }
        }

        if tickCount % diskEveryNTicks == 0 {
            lastDisk = SystemStats.bootVolumeCapacity()
        }
        tickCount &+= 1

        let memory = MemoryMath.compute(pages: pages,
                                        pageSize: SystemStats.pageSize,
                                        total: SystemStats.totalRAM,
                                        pressureRaw: SystemStats.pressureLevel())
        let uptime = bootDate.map { Date().timeIntervalSince($0) } ?? 0
        emit(Sample(cpuBusy: busy, memory: memory, disk: lastDisk, uptime: uptime))
    }

    private func emit(_ sample: Sample) {
        if Thread.isMainThread { onUpdate?(sample) }
        else { DispatchQueue.main.async { [weak self] in self?.onUpdate?(sample) } }
    }
}
