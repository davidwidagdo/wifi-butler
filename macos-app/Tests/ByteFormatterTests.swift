import Foundation

func testByteFormatter() {
    // Pin the locale so decimal separators are deterministic in the test.
    ByteFormatter.locale = Locale(identifier: "en_US_POSIX")

    T.eq(ByteFormatter.speed(0),          "0 B/s",     "speed 0")
    T.eq(ByteFormatter.speed(999),        "999 B/s",   "speed 999")
    T.eq(ByteFormatter.speed(1000),       "1 KB/s",    "speed 1000")
    T.eq(ByteFormatter.speed(1500),       "1.5 KB/s",  "speed 1500")
    T.eq(ByteFormatter.speed(10500),      "10.5 KB/s", "speed 10500")
    T.eq(ByteFormatter.speed(150000),     "150 KB/s",  "speed 150000")
    T.eq(ByteFormatter.speed(1_500_000),  "1.5 MB/s",  "speed 1.5 MB")

    T.eq(ByteFormatter.total(0),               "0 B",       "total 0")
    T.eq(ByteFormatter.total(512),             "512 B",     "total 512")
    T.eq(ByteFormatter.total(1_500_000),       "1.5 MB",    "total 1.5 MB")
    T.eq(ByteFormatter.total(17_820_000_000),  "17.82 GB",  "total 17.82 GB")
    T.eq(ByteFormatter.total(1024, binary: true),      "1 KB", "total 1024 binary")
    T.eq(ByteFormatter.total(1_048_576, binary: true), "1 MB", "total 1 MiB binary")

    // Rounding must promote the unit rather than print "1000 KB/s" / "1000 MB".
    T.eq(ByteFormatter.speed(999_600),      "1 MB/s", "speed rounds up to next unit")
    T.eq(ByteFormatter.total(999_960_000),  "1 GB",   "total rounds up to next unit")
    T.eq(ByteFormatter.speed(950_000),      "950 KB/s", "no false promotion below boundary")
}
