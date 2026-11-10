import CloudKit
import Foundation

/// Maps a `DeviceEnvelope` to the CloudKit record of ADR 0013 → CloudKit
/// layout and back: record type `AlertMessage` or `QuietMessage`, the
/// message ID as record name, the recipient's inbox zone, and exactly the
/// six fields below. `CloudKit/schema.ckdb` declares the same fields.
public enum CloudKitMessageRecord {
    public enum Field: String, CaseIterable, Sendable {
        case sender
        case recipient
        case kind
        case sentAt
        case expiresAt
        case body

        /// The field's type in the CloudKit schema language.
        public var schemaType: String {
            switch self {
            case .sender, .recipient: return "STRING"
            case .kind: return "INT64"
            case .sentAt, .expiresAt: return "TIMESTAMP"
            case .body: return "BYTES"
            }
        }
    }

    public enum EncodingError: Error, Equatable, Sendable {
        /// The recipient is not a device ID, so it has no inbox zone.
        case invalidRecipient
        /// The record name is not a message ID.
        case invalidRecordName
    }

    /// The record that carries `envelope` into its recipient's inbox zone.
    public static func record(for envelope: DeviceEnvelope) throws -> CKRecord {
        guard let recipient = DeviceID(text: envelope.recipient) else { throw EncodingError.invalidRecipient }
        guard MessageID(text: envelope.recordName) != nil else { throw EncodingError.invalidRecordName }
        let recordID = CKRecord.ID(recordName: envelope.recordName, zoneID: CloudKitInboxLayout.zoneID(for: recipient))
        let record = CKRecord(recordType: envelope.recordType.rawValue, recordID: recordID)
        record[Field.sender.rawValue] = envelope.sender as NSString
        record[Field.recipient.rawValue] = envelope.recipient as NSString
        record[Field.kind.rawValue] = NSNumber(value: envelope.kind)
        record[Field.sentAt.rawValue] = envelope.sentAt as NSDate
        record[Field.expiresAt.rawValue] = envelope.expiresAt as NSDate
        record[Field.body.rawValue] = envelope.body as NSData
        return record
    }

    /// The envelope a fetched record carries, or nil when the record is not
    /// one: an unknown record type, a missing or extra field, a field of the
    /// wrong type, or a known kind whose record type is not this record's.
    /// An unknown kind is passed on, so the recipient refuses it as
    /// `DeviceMessageRefusal.unknownKind`. The values are routing hints until
    /// the recipient has verified the signed message.
    public static func envelope(from record: CKRecord) -> DeviceEnvelope? {
        guard let recordType = MessageRecordType(rawValue: record.recordType),
              Set(record.allKeys()) == Set(Field.allCases.map(\.rawValue)),
              let sender = record[Field.sender.rawValue] as? String,
              let recipient = record[Field.recipient.rawValue] as? String,
              let kind = integer(record[Field.kind.rawValue]),
              let sentAt = record[Field.sentAt.rawValue] as? Date,
              let expiresAt = record[Field.expiresAt.rawValue] as? Date,
              let body = record[Field.body.rawValue] as? Data else {
            return nil
        }
        if let known = UInt8(exactly: kind).flatMap(MessageKind.init(rawValue:)), known.recordType != recordType {
            return nil
        }
        return DeviceEnvelope(recordType: recordType, recordName: record.recordID.recordName, sender: sender,
                              recipient: recipient, kind: kind, sentAt: sentAt, expiresAt: expiresAt, body: body)
    }

    /// An `INT64` field arrives as an integer `NSNumber`, in whatever integer
    /// encoding; a Boolean, a floating-point number or any other value is the
    /// wrong type.
    private static func integer(_ value: CKRecordValue?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        switch String(cString: number.objCType) {
        case "f", "d":
            return nil
        case "Q", "L", "I", "S", "C":
            return Int64(exactly: number.uint64Value)
        default:
            return number.int64Value
        }
    }
}
