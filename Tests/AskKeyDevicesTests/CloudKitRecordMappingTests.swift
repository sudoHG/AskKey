@testable import AskKeyDevices
import AskKeyDevicesTestSupport
import CloudKit
import XCTest

final class CloudKitRecordMappingTests: XCTestCase {
    private let sender = SoftwareDeviceIdentity().deviceID
    private let recipient = SoftwareDeviceIdentity().deviceID

    private func envelope(_ kind: MessageKind, recordType: MessageRecordType? = nil) -> DeviceEnvelope {
        DeviceEnvelope(recordType: recordType ?? kind.recordType, recordName: MessageID.random().text,
                       sender: sender.text, recipient: recipient.text, kind: Int64(kind.rawValue),
                       sentAt: Date(timeIntervalSince1970: 1_800_000_000), expiresAt: Date(timeIntervalSince1970: 1_800_000_600),
                       body: Data([1]) + Data(repeating: 0xAB, count: 96))
    }

    func testBothRecordTypesMapToARecordAndBackUnchanged() throws {
        for kind in [MessageKind.deliveryCheck, .pairingChallenge, .unpairNotice, .pairingReveal] {
            let original = envelope(kind)
            let record = try CloudKitMessageRecord.record(for: original)
            XCTAssertEqual(record.recordType, kind.recordType.rawValue, "\(kind)")
            XCTAssertEqual(record.recordID.recordName, original.recordName, "the message ID is the record name")
            XCTAssertEqual(record.recordID.zoneID.zoneName, "inbox_" + recipient.text, "the recipient's inbox")
            XCTAssertEqual(record.recordID.zoneID.ownerName, CKCurrentUserDefaultName)
            XCTAssertEqual(Set(record.allKeys()), ["sender", "recipient", "kind", "sentAt", "expiresAt", "body"])
            XCTAssertEqual(record["sender"] as? String, sender.text)
            XCTAssertEqual(record["recipient"] as? String, recipient.text)
            XCTAssertEqual((record["kind"] as? NSNumber)?.int64Value, Int64(kind.rawValue))
            XCTAssertEqual(record["sentAt"] as? Date, original.sentAt)
            XCTAssertEqual(record["expiresAt"] as? Date, original.expiresAt)
            XCTAssertEqual(record["body"] as? Data, original.body)
            XCTAssertEqual(CloudKitMessageRecord.envelope(from: record), original)
        }
        XCTAssertEqual(MessageKind.deliveryCheck.recordType.rawValue, "AlertMessage")
        XCTAssertEqual(MessageKind.pairingReveal.recordType.rawValue, "QuietMessage")
    }

    func testMalformedRecordsAreRefused() throws {
        let good = try CloudKitMessageRecord.record(for: envelope(.deliveryCheck))
        XCTAssertNotNil(CloudKitMessageRecord.envelope(from: good))

        let unknownType = CKRecord(recordType: "ProbeMessage", recordID: good.recordID)
        for key in good.allKeys() { unknownType[key] = good[key] }
        XCTAssertNil(CloudKitMessageRecord.envelope(from: unknownType), "unknown record type")

        for field in CloudKitMessageRecord.Field.allCases {
            let missing = copy(good)
            missing[field.rawValue] = nil
            XCTAssertNil(CloudKitMessageRecord.envelope(from: missing), "missing \(field)")
        }

        let extra = copy(good)
        extra["note"] = "hello" as NSString
        XCTAssertNil(CloudKitMessageRecord.envelope(from: extra), "extra field")

        let wrongTypes: [(String, CKRecordValue)] = [
            ("sender", NSNumber(value: 1)),
            ("recipient", Data([1]) as NSData),
            ("kind", "7" as NSString),
            ("kind", NSNumber(value: 7.0)),
            ("kind", NSNumber(value: true)),
            ("sentAt", "2027-01-15T08:00:00Z" as NSString),
            ("expiresAt", NSNumber(value: 1_800_000_600)),
            ("body", "AQ==" as NSString),
        ]
        for (field, value) in wrongTypes {
            let record = copy(good)
            record[field] = value
            XCTAssertNil(CloudKitMessageRecord.envelope(from: record), "\(field) as \(type(of: value))")
        }
    }

    func testRecordTypeMustMatchTheKind() throws {
        let checkAsQuiet = try CloudKitMessageRecord.record(for: envelope(.deliveryCheck, recordType: .quiet))
        XCTAssertNil(CloudKitMessageRecord.envelope(from: checkAsQuiet))
        let requestAsAlert = try CloudKitMessageRecord.record(for: envelope(.pairingRequest, recordType: .alert))
        XCTAssertNil(CloudKitMessageRecord.envelope(from: requestAsAlert))

        var unknown = envelope(.pairingChallenge)
        unknown.kind = 200
        let decoded = CloudKitMessageRecord.envelope(from: try CloudKitMessageRecord.record(for: unknown))
        XCTAssertEqual(decoded, unknown, "an unknown kind is left to the messenger, which refuses it as unknownKind")
    }

    func testEncodingRefusesAnInvalidRecipientOrRecordName() {
        var badRecipient = envelope(.deliveryCheck)
        badRecipient.recipient = "not-a-device"
        XCTAssertThrowsError(try CloudKitMessageRecord.record(for: badRecipient)) {
            XCTAssertEqual($0 as? CloudKitMessageRecord.EncodingError, .invalidRecipient)
        }
        var badName = envelope(.deliveryCheck)
        badName.recordName = ""
        XCTAssertThrowsError(try CloudKitMessageRecord.record(for: badName)) {
            XCTAssertEqual($0 as? CloudKitMessageRecord.EncodingError, .invalidRecordName)
        }
    }

    func testRecordFieldsEqualTheSchemaFile() throws {
        let schema = try SchemaFile.load()
        XCTAssertEqual(Set(schema.recordTypes.keys).subtracting(["Users"]), Set(MessageRecordType.allCases.map(\.rawValue)))
        let mapped = Dictionary(uniqueKeysWithValues: CloudKitMessageRecord.Field.allCases.map { ($0.rawValue, $0.schemaType) })
        for recordType in MessageRecordType.allCases {
            XCTAssertEqual(schema.recordTypes[recordType.rawValue], mapped, recordType.rawValue)
        }
        let record = try CloudKitMessageRecord.record(for: envelope(.deliveryCheck))
        XCTAssertEqual(Set(record.allKeys()), Set(try XCTUnwrap(schema.recordTypes["AlertMessage"]).keys))
        XCTAssertFalse(schema.indexedFields.contains { !$0.hasPrefix("___") },
                       "no custom field needs an index: the subscriptions use TRUEPREDICATE")
    }

    private func copy(_ record: CKRecord) -> CKRecord {
        let copy = CKRecord(recordType: record.recordType, recordID: record.recordID)
        for key in record.allKeys() { copy[key] = record[key] }
        return copy
    }
}

/// `CloudKit/schema.ckdb`, read as the CloudKit schema language: each record
/// type's custom fields (system fields start with `___`) and their types.
struct SchemaFile {
    var recordTypes: [String: [String: String]] = [:]
    var indexedFields: [String] = []

    static func load() throws -> SchemaFile {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("CloudKit/schema.ckdb"), encoding: .utf8)
        var schema = SchemaFile()
        var current: String?
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("RECORD TYPE ") {
                let name = line.dropFirst("RECORD TYPE ".count).prefix { $0 != " " && $0 != "(" }
                current = String(name)
                schema.recordTypes[String(name)] = [:]
                continue
            }
            if line.hasPrefix(");") { current = nil; continue }
            guard let recordType = current, !line.isEmpty, !line.hasPrefix("GRANT ") else { continue }
            let parts = line.trimmingCharacters(in: CharacterSet(charactersIn: ",")).split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { continue }
            let name = parts[0].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if parts.dropFirst(2).contains(where: { ["QUERYABLE", "SORTABLE", "SEARCHABLE"].contains($0) }) {
                schema.indexedFields.append(name)
            }
            guard !name.hasPrefix("___") else { continue }
            schema.recordTypes[recordType]?[name] = String(parts[1])
        }
        return schema
    }
}
