import Foundation

/// A binary structure did not have the exact layout ADR 0013 specifies.
struct MalformedEncoding: Error {}

/// Builds the big-endian binary layouts of ADR 0013 → Encodings.
struct ByteWriter {
    private(set) var data = Data()

    mutating func append(_ byte: UInt8) {
        data.append(byte)
    }

    mutating func append(_ bytes: Data) {
        data.append(bytes)
    }

    mutating func appendUInt32(_ value: UInt32) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }

    mutating func appendUInt64(_ value: UInt64) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }

    /// Times are 8-byte big-endian Unix seconds.
    mutating func appendTime(_ seconds: Int64) {
        precondition(seconds >= 0, "times before 1970 are not encoded")
        appendUInt64(UInt64(seconds))
    }

    /// A variable-length field: a 4-byte big-endian length, then the bytes.
    mutating func appendLengthPrefixed(_ bytes: Data) {
        appendUInt32(UInt32(bytes.count))
        data.append(bytes)
    }
}

/// Reads a binary layout strictly: every read is bounds-checked and
/// `finish()` refuses trailing bytes.
struct ByteReader {
    private let data: Data
    private var offset = 0

    init(_ bytes: Data) {
        data = Data(bytes) // A copy indexed from zero, even when the input is a slice.
    }

    var remainingCount: Int { data.count - offset }

    mutating func readByte() throws -> UInt8 {
        guard remainingCount >= 1 else { throw MalformedEncoding() }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func readBytes(_ count: Int) throws -> Data {
        guard count >= 0, remainingCount >= count else { throw MalformedEncoding() }
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }

    mutating func readUInt32() throws -> UInt32 {
        try readBytes(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }

    mutating func readUInt64() throws -> UInt64 {
        try readBytes(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    }

    /// Refuses times after the year 9999, which no layout ever needs and
    /// which `Date` cannot carry exactly.
    mutating func readTime() throws -> Int64 {
        let value = try readUInt64()
        guard value <= UInt64(UnixTime.maximumSeconds) else { throw MalformedEncoding() }
        return Int64(value)
    }

    mutating func readLengthPrefixed(maximumCount: Int) throws -> Data {
        let count = try readUInt32()
        guard count <= UInt32(maximumCount) else { throw MalformedEncoding() }
        return try readBytes(Int(count))
    }

    mutating func readRemaining() -> Data {
        defer { offset = data.count }
        return data.subdata(in: offset..<data.count)
    }

    func finish() throws {
        guard remainingCount == 0 else { throw MalformedEncoding() }
    }
}

/// Every domain label in ADR 0013 is ASCII followed by one NUL byte.
enum DomainLabel {
    static let deviceID = label("AskKey device id v1")
    static let deviceCard = label("AskKey device card v1")
    static let message = label("AskKey message v1")
    static let hpkeInfo = label("AskKey HPKE v1")
    static let pairingPreSharedKey = label("AskKey pairing psk v1")
    static let pairingTranscript = label("AskKey pairing transcript v1")
    static let comparisonCode = label("AskKey comparison code v1")
    static let pairingConfirmation = label("AskKey pairing confirmation v1")
    static let pairingID = label("AskKey pairing id v1")

    private static func label(_ text: String) -> Data {
        precondition(text.allSatisfy(\.isASCII))
        return Data(text.utf8) + [0]
    }
}

/// Unix seconds as the layouts carry them. Sub-second parts are dropped.
enum UnixTime {
    /// The last second of the year 9999.
    static let maximumSeconds: Int64 = 253_402_300_799

    /// Clamped to 0 ... `maximumSeconds`, so no date can trap the conversion.
    static func seconds(_ date: Date) -> Int64 {
        let interval = date.timeIntervalSince1970.rounded(.down)
        guard interval.isFinite else { return interval > 0 ? maximumSeconds : 0 }
        return Int64(min(max(interval, 0), Double(maximumSeconds)))
    }

    static func date(_ seconds: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    /// The seconds a plaintext date stands for, or nil if it is not a whole
    /// non-negative second, so it can be compared exactly with a signed time.
    static func exactSeconds(_ date: Date) -> Int64? {
        let interval = date.timeIntervalSince1970
        guard interval >= 0, interval.rounded(.down) == interval, interval <= Double(maximumSeconds) else { return nil }
        return Int64(exactly: interval)
    }
}
