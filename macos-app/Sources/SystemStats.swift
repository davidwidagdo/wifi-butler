import Foundation
import Darwin

// Reads CPU, memory, disk and boot time from the kernel. Impure by nature and
// therefore untested — every calculation lives in CPUMath / MemoryMath / DiskMath
// (same split as NetworkStats vs SpeedMath).
enum SystemStats {
    // mach_host_self() takes a NEW send right on every call and never drops it —
    // measured at +1000 rights for 1000 calls. At 1 Hz that is ~86k leaked rights
    // a day, so take exactly one for the lifetime of the process.
    private static let host: host_t = mach_host_self()

    // Neither of these ever changes while the machine is running.
    static let pageSize: UInt64 = UInt64(vm_kernel_page_size)
    static let totalRAM: UInt64 = sysctlUInt64("hw.memsize") ?? 0

    // MARK: - CPU

    static func cpuTicks() -> CPUMath.Ticks? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, host_flavor_t(HOST_CPU_LOAD_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        // cpu_ticks is a C array, imported as a 4-tuple. Indices are
        // CPU_STATE_USER / SYSTEM / IDLE / NICE = 0 / 1 / 2 / 3.
        //
        // Deliberately NOT host_processor_info (per-core): that one returns
        // out-of-line memory which must be vm_deallocate'd, and we don't need it.
        return CPUMath.Ticks(user: info.cpu_ticks.0, system: info.cpu_ticks.1,
                             idle: info.cpu_ticks.2, nice: info.cpu_ticks.3)
    }

    // MARK: - Memory

    static func memoryPages() -> MemoryMath.Pages? {
        // Zero-initialised so a shorter reply from an older kernel degrades to 0
        // rather than garbage; host_statistics64 writes back what it filled.
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, host_flavor_t(HOST_VM_INFO64), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return MemoryMath.Pages(internalPages: UInt64(stats.internal_page_count),
                                purgeable: UInt64(stats.purgeable_count),
                                wired: UInt64(stats.wire_count),
                                compressed: UInt64(stats.compressor_page_count),
                                external: UInt64(stats.external_page_count),
                                free: UInt64(stats.free_count))
    }

    // The kernel's own pressure level, the same signal Activity Monitor graphs.
    // Not a percentage of used RAM — don't invent one. The sysctl name isn't in a
    // public SDK header, so a missing key falls back to "normal".
    static func pressureLevel() -> Int32 {
        sysctlInt32("kern.memorystatus_vm_pressure_level") ?? 1
    }

    // MARK: - Disk

    static func bootVolumeCapacity() -> DiskMath.Capacity? {
        // `statfs` names both a struct and a function; going through withCString
        // disambiguates to the function.
        var fs = statfs()
        let ok = "/".withCString { statfs($0, &fs) }
        guard ok == 0, fs.f_blocks > 0 else { return nil }
        let block = UInt64(fs.f_bsize)
        // f_bavail (not f_bfree) is the non-superuser figure, matching what Finder
        // and `df` call "Available". On an APFS container both f_blocks and
        // f_bavail describe the whole container, which is what we want.
        return DiskMath.Capacity(total: UInt64(fs.f_blocks) * block,
                                 free: UInt64(fs.f_bavail) * block)
    }

    // MARK: - Uptime

    // Wall-clock boot time. ProcessInfo.systemUptime is mach-based and STOPS
    // during sleep, so on a laptop it drifts hours behind `uptime(1)`.
    static func bootDate() -> Date? {
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        var tv = timeval()
        var size = MemoryLayout<timeval>.stride
        guard sysctl(&mib, 2, &tv, &size, nil, 0) == 0, tv.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
    }

    // MARK: - sysctl helpers

    private static func sysctlInt32(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    private static func sysctlUInt64(_ name: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }
}
