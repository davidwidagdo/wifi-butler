import Foundation
import Darwin

// Reads cumulative rx/tx byte counters for a BSD interface using the routing
// socket's NET_RT_IFLIST2 dump, which exposes 64-bit if_data64 counters — no
// 32-bit overflow, unlike getifaddrs' if_data.
enum NetworkStats {
    static func counters(for name: String) -> (rx: UInt64, tx: UInt64)? {
        let index = if_nametoindex(name)
        guard index != 0 else { return nil }

        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return nil }

        return buf.withUnsafeBytes { raw -> (UInt64, UInt64)? in
            guard let base = raw.baseAddress else { return nil }
            var off = 0
            while off + MemoryLayout<if_msghdr>.size <= len {
                let hdr = base.advanced(by: off).assumingMemoryBound(to: if_msghdr.self).pointee
                let msgLen = Int(hdr.ifm_msglen)
                if msgLen <= 0 { break }
                if Int32(hdr.ifm_type) == RTM_IFINFO2,
                   off + MemoryLayout<if_msghdr2>.size <= len {
                    let m2 = base.advanced(by: off).assumingMemoryBound(to: if_msghdr2.self).pointee
                    if UInt32(m2.ifm_index) == index {
                        return (m2.ifm_data.ifi_ibytes, m2.ifm_data.ifi_obytes)
                    }
                }
                off += msgLen
            }
            return nil
        }
    }
}
