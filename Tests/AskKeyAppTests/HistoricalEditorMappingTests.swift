import CryptoKit
import GRDB
import XCTest
import AskKeyBroker
@testable import AskKeyAppKit
@testable import AskKeyVault

@MainActor
final class HistoricalEditorMappingTests: AskKeyAppTestCase {
    func testAuthenticatedV032BundleLoadsWithValuesAndSettingsThenSavesOnlyAfterRepair() throws {
        let fixture = try HistoricalEditorMappingFixture()
        defer { fixture.close() }
        let vault = fixture.vault
        XCTAssertEqual(vault.componentMetadataIssue?.reason, .backfill)
        XCTAssertThrowsError(try vault.brokerCredentialCatalog()) {
            XCTAssertEqual($0 as? BrokerProviderError, .agentAccessPaused)
        }
        try vault.beginManagementSession(using: .allow)
        let original = try vault.revealTextCredential(id: fixture.id, using: .allow)
        var drafts = try CredentialEditorComponentLoader.load(original.components)
        XCTAssertEqual(drafts.map(\.name), ["Token", "Certificate"])
        XCTAssertEqual(drafts[0].text, "synthetic-token")
        XCTAssertEqual(drafts[0].delivery, .environmentVariable("FOO\n"))
        XCTAssertFalse(drafts[0].masked)
        XCTAssertEqual(drafts[1].kind, .file)
        XCTAssertEqual(drafts[1].file?.originalFilename, "synthetic.pem")
        XCTAssertEqual(drafts[1].file?.bytes, Data("synthetic-certificate".utf8))
        XCTAssertEqual(drafts[1].delivery, .temporaryFile("CERT_PATH"))
        XCTAssertTrue(drafts[1].masked)
        let previousLanguage = AppLanguage.current
        defer { AppLanguage.current = previousLanguage }
        for language in ["en", "zh-Hans"] {
            AppLanguage.current = language
            XCTAssertEqual(CredentialEditorComponentValidation.deliveryError(drafts[0]),
                appLocalized("This name ends with an extra line break or space. Delete it to save."))
        }
        XCTAssertFalse(CredentialEditorComponentValidation.canSave(drafts))
        XCTAssertNil(CredentialEditorComponentValidation.inputs(drafts))
        let invalid = fixture.input(components: original.components.map {
            CredentialComponentInput(name: $0.name, value: $0.value!, delivery: $0.delivery, masked: $0.masked)
        })
        XCTAssertThrowsError(try vault.updateBundleCredential(id: fixture.id, invalid, using: .allow))
        XCTAssertEqual(try vault.revealTextCredential(id: fixture.id, using: .allow), original)

        let fieldValue = try XCTUnwrap(drafts[0].delivery?.environmentVariable)
        drafts[0].delivery = .environmentVariable(String(fieldValue.dropLast()))
        XCTAssertNil(CredentialEditorComponentValidation.deliveryError(drafts[0]))
        XCTAssertTrue(CredentialEditorComponentValidation.canSave(drafts))
        let inputs = try XCTUnwrap(CredentialEditorComponentValidation.inputs(drafts))
        _ = try vault.updateBundleCredential(id: fixture.id, fixture.input(components: inputs), using: .allow)
        let saved = try vault.revealTextCredential(id: fixture.id, using: .allow)
        XCTAssertEqual(saved.components[0].value, original.components[0].value)
        XCTAssertEqual(saved.components[0].delivery, .environmentVariable("FOO"))
        XCTAssertEqual(saved.components[0].masked, original.components[0].masked)
        XCTAssertEqual(saved.components[1], original.components[1])
        XCTAssertEqual(saved.usageInstructions, original.usageInstructions)
        XCTAssertEqual(saved.privateNotes, original.privateNotes)
        XCTAssertEqual(saved.groupName, original.groupName)
        XCTAssertEqual(saved.permission, original.permission)
        XCTAssertEqual(saved.expiresAt, original.expiresAt)
        try fixture.store.close()
        let reopened = try VaultStore(path: fixture.databaseURL.path, authenticationKey: fixture.key)
        defer { try? reopened.close() }
        XCTAssertNil(reopened.componentMetadataIssue)
        XCTAssertEqual(try Vault(store: reopened, key: fixture.key).brokerCredentialCatalog().count, 1)
    }

    func testLoadingStillRequiresRevealedComponentValues() {
        XCTAssertThrowsError(try CredentialEditorComponentLoader.load([
            .init(name: "Token", value: nil)
        ]))
    }

    func testDeletingTrailingLineBreakOrSpaceMakesTheDraftValidInBothLanguages() throws {
        let previousLanguage = AppLanguage.current
        defer { AppLanguage.current = previousLanguage }
        let messageKey = "This name ends with an extra line break or space. Delete it to save."
        for language in ["en", "zh-Hans"] {
            AppLanguage.current = language
            let message = appLocalized(messageKey)
            if language == "zh-Hans" { XCTAssertNotEqual(message, messageKey) }
            for mapping in ["FOO\n", "FOO "] {
                for delivery in [CredentialComponentDelivery.environmentVariable(mapping), .temporaryFile(mapping)] {
                    var draft = try XCTUnwrap(CredentialEditorComponentLoader.load([
                        .init(name: "Token", value: .text("synthetic-token"), delivery: delivery)
                    ]).first)
                    XCTAssertEqual(CredentialEditorComponentValidation.deliveryError(draft), message)
                    XCTAssertFalse(CredentialEditorComponentValidation.canSave([draft]))
                    XCTAssertEqual(draft.delivery, delivery)
                    let fieldValue = try XCTUnwrap(draft.delivery?.environmentVariable)
                    let edited = String(fieldValue.dropLast())
                    if case .temporaryFile = delivery { draft.delivery = .temporaryFile(edited) }
                    else { draft.delivery = .environmentVariable(edited) }
                    XCTAssertNil(CredentialEditorComponentValidation.deliveryError(draft))
                    XCTAssertTrue(CredentialEditorComponentValidation.canSave([draft]))
                    XCTAssertEqual(CredentialEditorComponentValidation.inputs([draft])?.first?.value, .text("synthetic-token"))
                }
            }
        }
    }

    func testOtherInvalidMappingsKeepTheGenericErrorInBothLanguages() throws {
        let previousLanguage = AppLanguage.current
        defer { AppLanguage.current = previousLanguage }
        for language in ["en", "zh-Hans"] {
            AppLanguage.current = language
            for mapping in ["9FOO", "FOO BAR", "FOO-BAR\n", " "] {
                let draft = try XCTUnwrap(CredentialEditorComponentLoader.load([
                    .init(name: "Token", value: .text("synthetic-token"), delivery: .environmentVariable(mapping))
                ]).first)
                XCTAssertEqual(CredentialEditorComponentValidation.deliveryError(draft),
                    appLocalized(VaultError.invalidSecretName(mapping).localizedDescription))
                XCTAssertFalse(CredentialEditorComponentValidation.canSave([draft]))
            }
        }
    }

    func testTemplateInferencePreservesHistoricalTextInAFileNamedSlot() throws {
        let components: [ManagedCredentialComponent] = [
            .init(name: "SSH_HOST", value: .text("synthetic.example")),
            .init(name: "SSH_PRIVATE_KEY", value: .text("synthetic-private-key"),
                delivery: .environmentVariable("FOO\n"), masked: false)
        ]
        let template = CredentialTemplate.prototypeTemplate(componentNames: Set(components.map(\.name)))
        XCTAssertEqual(template, .ssh)
        var drafts = try CredentialEditorComponentLoader.load(components, template: template)
        XCTAssertEqual(drafts[1].kind, .text)
        XCTAssertEqual(drafts[1].text, "synthetic-private-key")
        XCTAssertFalse(drafts[1].masked)
        XCTAssertFalse(CredentialEditorComponentValidation.canSave(drafts))
        drafts[1].delivery = .environmentVariable("FOO")
        XCTAssertTrue(CredentialEditorComponentValidation.canSave(drafts))
        XCTAssertEqual(CredentialEditorComponentValidation.inputs(drafts)?.last?.value, .text("synthetic-private-key"))
    }

    func testDefaultMappingsValidateTheTrimmedSavedNameAndIgnoreBlankRows() {
        let complete = CredentialComponentDraft(name: " TOKEN ", text: "synthetic")
        XCTAssertNil(CredentialEditorComponentValidation.deliveryError(CredentialComponentDraft()))
        XCTAssertTrue(CredentialEditorComponentValidation.canSave([complete, CredentialComponentDraft()]))
        XCTAssertEqual(CredentialEditorComponentValidation.inputs([complete])?.first?.delivery,
            .environmentVariable("TOKEN"))
    }
}

/// Authenticated pre-0003 storage, including the trailing newline v0.3.2 accepted.
@MainActor
final class HistoricalEditorMappingFixture {
    let directory: URL
    let databaseURL: URL
    let key = VaultCrypto.generateKey()
    let store: VaultStore
    let vault: Vault
    let id: String

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("HistoricalEditor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        databaseURL = directory.appendingPathComponent("v032.db")
        let seed = try VaultStore(path: directory.appendingPathComponent("seed.db").path)
        defer { try? seed.close() }
        let seedVault = Vault(store: seed, key: key)
        try seedVault.beginManagementSession(using: .allow)
        let created = try seedVault.createBundleCredential(Self.input(components: [
            .init(name: "Token", value: .text("synthetic-token"), delivery: .environmentVariable("FOO"), masked: false),
            .init(name: "Certificate", value: .file(filename: "synthetic.pem", bytes: Data("synthetic-certificate".utf8)),
                delivery: .temporaryFile("CERT_PATH"))
        ]), using: .allow)
        id = created.id
        var record = try XCTUnwrap(seed.fetchCredential(id: created.id))
        var historical = try JSONDecoder().decode([CredentialComponentInput].self,
            from: VaultCrypto.decryptData(record.encryptedPayload, using: key))
        historical[0].delivery = .environmentVariable("FOO\n")
        record.encryptedPayload = try VaultCrypto.encrypt(JSONEncoder().encode(historical), using: key)
        record.encryptedComponentMetadata = nil
        record.includesComponentMetadataColumn = false
        let database = try DatabaseQueue(path: databaseURL.path)
        try CurrentLibrarySchema.migrator().migrate(database, upTo: CurrentLibrarySchema.dropLegacyTablesIdentifier)
        let authenticationKey = key
        try database.write { try CredentialRecordAuthentication.seal(record, using: authenticationKey).insert($0) }
        try database.close()
        store = try VaultStore(path: databaseURL.path, authenticationKey: key)
        vault = Vault(store: store, key: key)
    }

    func input(components: [CredentialComponentInput]) -> BundleCredentialInput {
        Self.input(components: components)
    }

    private static func input(components: [CredentialComponentInput]) -> BundleCredentialInput {
        .init(name: "Synthetic historical bundle", components: components,
            usageInstructions: "Synthetic usage", privateNotes: "Synthetic private note",
            permission: .ask, expiresAt: Date(timeIntervalSince1970: 2_000_000_000))
    }

    func close() {
        try? store.close()
        try? FileManager.default.removeItem(at: directory)
    }
}
