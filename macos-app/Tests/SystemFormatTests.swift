import Foundation

func testSystemFormat() {
    // Disk: used is always total - free (the APFS container rule).
    let cap = DiskMath.Capacity(total: 494_384_795_648, free: 118_549_053_440)
    T.eq(cap.used, 375_835_742_208, "disk used = total - free")
    T.expect(cap.usedFraction > 0.75 && cap.usedFraction < 0.77, "disk used fraction ~0.76")
    T.eq(DiskMath.Capacity(total: 0, free: 0).usedFraction, 0, "disk zero total -> 0")
    T.eq(DiskMath.Capacity(total: 100, free: 500).used, UInt64(0), "disk free > total clamps")
    T.eq(DiskMath.Capacity(total: 100, free: 500).usedFraction, 0, "disk free > total fraction 0")

    // Percent: rounds half up, clamps to 0...100.
    T.eq(SystemFormat.percent(0.755), "76%", "percent rounds half up")
    T.eq(SystemFormat.percent(0), "0%", "percent zero")
    T.eq(SystemFormat.percent(1), "100%", "percent one")
    T.eq(SystemFormat.percent(1.4), "100%", "percent clamps high")
    T.eq(SystemFormat.percent(-0.5), "0%", "percent clamps low")
    T.eq(SystemFormat.percent(.nan), "—", "percent nan")

    // Uptime: two most significant units, with the day/hour boundary exact.
    T.eq(SystemFormat.uptime(273_600), "3d 4h", "uptime days and hours")
    T.eq(SystemFormat.uptime(86_400), "1d 0h", "uptime exactly one day")
    T.eq(SystemFormat.uptime(86_399), "23h 59m", "uptime just under a day")
    T.eq(SystemFormat.uptime(3_600), "1h 0m", "uptime exactly one hour")
    T.eq(SystemFormat.uptime(3_599), "59m", "uptime just under an hour")
    T.eq(SystemFormat.uptime(59), "0m", "uptime under a minute")
    T.eq(SystemFormat.uptime(-5), "—", "uptime negative clock")
    T.eq(SystemFormat.uptime(.nan), "—", "uptime nan")

    // Pressure labels.
    T.eq(SystemFormat.pressureLabel(.normal), "Normal", "pressure label normal")
    T.eq(SystemFormat.pressureLabel(.warning), "Warning", "pressure label warning")
    T.eq(SystemFormat.pressureLabel(.critical), "Critical", "pressure label critical")
}
