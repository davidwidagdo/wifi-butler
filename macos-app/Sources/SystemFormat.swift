import Foundation

// Formats system metrics for display. Bytes are deliberately NOT handled here —
// they go through ByteFormatter so disk sizes match the speed meter's units.
enum SystemFormat {
    // Fixed-width by construction (up to "100%") so an open menu, which does not
    // re-measure its width, never truncates a growing value.
    static func percent(_ fraction: Double) -> String {
        guard fraction.isFinite else { return "—" }
        let clamped = min(1, max(0, fraction))
        return "\(Int((clamped * 100).rounded()))%"
    }

    // Two most significant units: "3d 4h", "23h 59m", "12m".
    static func uptime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        let total = Int(seconds)
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    static func pressureLabel(_ pressure: MemoryMath.Pressure) -> String {
        switch pressure {
        case .normal:   return "Normal"
        case .warning:  return "Warning"
        case .critical: return "Critical"
        }
    }
}
