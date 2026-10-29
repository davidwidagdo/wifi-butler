import Foundation
import Darwin

// Finds the heaviest processes. Two backends, because neither alone is right:
//
//  - `ps` is setuid root, so it is the only unprivileged way to see processes
//    owned by other users — which on a normal Mac includes WindowServer,
//    mds_stores and kernel_task, routinely the actual cause of a hot fan.
//    It costs a fork+exec (~20 ms), so it only runs when the user opens a
//    top-process submenu.
//  - libproc needs no subprocess but returns EPERM for other users' processes
//    (measured: 418 of 612 visible), so it is the fallback when `ps` is
//    unavailable — e.g. if the app is ever sandboxed.
enum ProcessStats {
    struct Row {
        let pid: Int32
        let name: String
        let cpuCores: Double   // 1.0 == one core saturated
        let rss: UInt64        // bytes
    }

    struct Listing {
        let rows: [Row]
        let fullCoverage: Bool   // false when the fallback saw only our own processes
    }

    // Synchronous and ~20 ms — call it off the main thread.
    static func listing() -> Listing {
        if let rows = psRows(), !rows.isEmpty {
            return Listing(rows: rows, fullCoverage: true)
        }
        return Listing(rows: libprocRows(), fullCoverage: false)
    }

    // MARK: - ps backend (full coverage)

    private static func psRows() -> [Row]? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        // -A all processes, -c command name only, -o our columns, -r sort by CPU.
        task.arguments = ["-Aco", "pid,pcpu,rss,comm", "-r"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
        } catch {
            Log.write("ps launch failed: \(error.localizedDescription)")
            return nil
        }
        // Read before waiting so a large listing can't fill the pipe buffer and
        // deadlock the child.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return parse(text)
    }

    // Columns are pid, %cpu, rss, then the command name — which may itself contain
    // spaces ("Google Chrome Helper (Renderer)"), so everything after the third
    // field is the name.
    static func parse(_ text: String) -> [Row] {
        var rows: [Row] = []
        for line in text.split(separator: "\n").dropFirst() {   // drop the header
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 4,
                  let pid = Int32(fields[0]),
                  let pcpu = Double(fields[1]),
                  let rssKB = UInt64(fields[2]) else { continue }
            let name = cleanName(fields[3...].joined(separator: " "))
            guard !name.isEmpty else { continue }
            rows.append(Row(pid: pid, name: name,
                            cpuCores: pcpu / 100,       // ps reports % of one core
                            rss: rssKB * 1024))          // ps reports KiB
        }
        return rows
    }

    // ps parenthesises the name of a process it can't fully read (usually one
    // that is exiting); strip that so it groups with its live siblings.
    private static func cleanName(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespaces)
        if name.hasPrefix("("), name.hasSuffix(")"), name.count > 2 {
            name = String(name.dropFirst().dropLast())
        }
        return name
    }

    // MARK: - libproc fallback (own processes only)

    private static func libprocRows() -> [Row] {
        let sizing = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard sizing > 0 else { return [] }
        // Headroom: processes can spawn between the sizing call and the real one,
        // and proc_listpids truncates silently.
        var pids = [pid_t](repeating: 0, count: Int(sizing) / MemoryLayout<pid_t>.size + 32)
        let got = pids.withUnsafeMutableBufferPointer {
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, $0.baseAddress,
                          Int32($0.count * MemoryLayout<pid_t>.size))
        }
        guard got > 0 else { return [] }

        var rows: [Row] = []
        var info = proc_taskinfo()
        let want = Int32(MemoryLayout<proc_taskinfo>.size)
        for index in 0..<(Int(got) / MemoryLayout<pid_t>.size) {
            let pid = pids[index]
            guard pid > 0 else { continue }
            // Returns 0 (EPERM) for another user's process — expected, not an error.
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, want) == want else { continue }
            // No CPU rate without a second sample; the fallback ranks by memory and
            // reports 0 cores rather than a misleading since-launch average.
            rows.append(Row(pid: pid, name: name(for: pid), cpuCores: 0, rss: info.pti_resident_size))
        }
        return rows
    }

    // PROC_PIDPATHINFO_MAXSIZE (4 * MAXPATHLEN) and MAXCOMLEN are computed macros,
    // so Swift does not import them — see sys/proc_info.h and sys/param.h.
    private static let maxPathSize = 4 * 1024
    private static let maxCommLen = 16

    // proc_pidpath works across users; proc_name does not.
    private static func name(for pid: Int32) -> String {
        var path = [CChar](repeating: 0, count: maxPathSize)
        if proc_pidpath(pid, &path, UInt32(path.count)) > 0 {
            let full = String(cString: path)
            if !full.isEmpty { return (full as NSString).lastPathComponent }
        }
        var comm = [CChar](repeating: 0, count: 2 * maxCommLen + 1)
        if proc_name(pid, &comm, UInt32(comm.count)) > 0 { return String(cString: comm) }
        return "pid \(pid)"
    }
}
