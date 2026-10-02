import XCTest
@testable import AskKeyCore

final class VaultWireProtocolTests: XCTestCase {
    func testRequestsRoundTripThroughJSON() throws {
        let requests: [VaultRequest] = [
            .unlock,
            .addProject(name: "App", icon: nil),
            .projectByID("p1"),
            .projectByName("App"),
            .listProjects,
            .deleteProjectIncludingContents(id: "p1"),
            .activeProjectID,
            .setActiveProject(id: "p1"),
            .addEnvironment(name: "staging", projectId: "p1", color: nil),
            .deleteEnvironmentIncludingContents(name: "staging", projectId: "p1"),
            .resolveProject(name: "App"),
            .get(name: "API_KEY", projectId: "p1", environmentName: nil),
            .add(name: "K", value: "v", description: "d", icon: nil, category: .apiKey, projectId: "p1", environmentName: "prod"),
            .set(name: "K", value: "v2", projectId: "p1", environmentName: nil),
            .delete(name: "K", projectId: "p1"),
            .listInfo(projectId: "p1"),
            .importEnv(pairs: [EnvPair(name: "A", value: "1")], projectId: "p1", environmentName: nil, overwrite: true),
            .createProjectFromEnv(name: "Imported", environmentName: "staging", pairs: [EnvPair(name: "A", value: "1")], overwrite: false),
            .setAgentAccess(name: "K", projectId: "p1", policy: .blocked),
            .secretCount(projectId: "p1", environmentName: nil),
            .totalSecretCount(projectId: "p1"),
            .listActivity(limit: 10, filter: ActivityFilter()),
            .export(projectId: "p1", passphrase: "pass"),
            .exportExcludingApprovalTier(projectId: "p1", passphrase: nil),
            .decryptExport(envelope: Data([1, 2, 3]), passphrase: "pass"),
            .logAccess(secretName: "K", projectName: "App", environmentName: "Default", source: .mcp, action: .read),
            .listEnvironments(projectId: "p1"),
            .setActiveEnvironment(name: "staging", projectId: "p1"),
            .setActiveEnvironment(name: nil, projectId: "p1"),
        ]
        for request in requests {
            let data = try JSONEncoder().encode(request)
            XCTAssertEqual(try JSONDecoder().decode(VaultRequest.self, from: data), request)
        }
    }

    func testEnvelopeRoundTripsThroughJSON() throws {
        let envelope = VaultEnvelope(
            agentContext: "agent",
            request: .get(name: "API_KEY", projectId: "p1", environmentName: nil)
        )
        let data = try JSONEncoder().encode(envelope)
        XCTAssertEqual(try JSONDecoder().decode(VaultEnvelope.self, from: data), envelope)
    }

    func testResponsesRoundTripThroughJSON() throws {
        let responses: [VaultResponse] = [
            .ok,
            .secret(Secret(name: "K", value: "v")),
            .secrets([Secret(name: "A", value: "1")]),
            .project(Project(id: "p1", name: "App")),
            .optionalProject(nil),
            .projects([Project(id: "p1", name: "App")]),
            .secretInfos([SecretInfo(name: "K", description: nil, icon: nil, category: .other)]),
            .environments([VaultEnvironment(id: "e1", projectId: "p1", name: "staging", color: nil)]),
            .importSummary(ImportSummary(added: 1, updated: 0, skipped: 2)),
            .projectImport(ProjectImportResult(project: Project(id: "p1", name: "App"), environmentName: "Default", summary: ImportSummary(added: 1, updated: 0, skipped: 0))),
            .optionalString("p1"),
            .count(2),
            .activity([]),
            .data(Data([1, 2, 3])),
            .exportResult(VaultExportResult(data: Data([4, 5]), skippedNames: ["GATED"])),
            .dictionary(["K": "v"]),
            .failure(message: "nope"),
        ]
        for response in responses {
            let data = try JSONEncoder().encode(response)
            XCTAssertEqual(try JSONDecoder().decode(VaultResponse.self, from: data), response)
        }
    }
}

/// Exercises the entire request → dispatch → response → result loop that the
/// socket will carry, but in-process: a RemoteVaultService whose transport is the
/// dispatcher against a real temp-store Vault. No socket, no Keychain.
final class RemoteVaultServiceLoopTests: XCTestCase {
    private func makeVault() throws -> Vault {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = try VaultStore(path: directory.appendingPathComponent("vault.db").path)
        return Vault(store: store, key: VaultCrypto.generateKey())
    }

    func testAddListGetRoundTripThroughTheLoop() throws {
        let vault = try makeVault()
        let project = try vault.addProject(name: "App")
        let remote = RemoteVaultService(transport: { VaultRequestDispatcher.handle($0, using: vault) })

        _ = try remote.add(name: "API_KEY", value: "sk-1", description: nil, icon: nil, category: nil, projectId: project.id, environmentName: nil)

        XCTAssertEqual(try remote.list(projectId: project.id, environmentName: nil).map(\.name), ["API_KEY"])
        XCTAssertEqual(try remote.get(name: "API_KEY", projectId: project.id, environmentName: nil).value, "sk-1")
        XCTAssertTrue(try remote.listProjects().map(\.name).contains("App"))
    }

    func testDaemonSideErrorSurfacesAsRemoteVaultError() throws {
        let vault = try makeVault()
        let project = try vault.addProject(name: "App")
        let remote = RemoteVaultService(transport: { VaultRequestDispatcher.handle($0, using: vault) })

        XCTAssertThrowsError(try remote.get(name: "MISSING", projectId: project.id, environmentName: nil)) { error in
            guard case RemoteVaultError.daemon(let message) = error else {
                return XCTFail("expected a daemon error, got \(error)")
            }
            XCTAssertTrue(message.contains("MISSING"))
        }
    }

    func testAdministrativeOperationsRoundTripThroughTheLoop() throws {
        let vault = try makeVault()
        let remote = RemoteVaultService(transport: { VaultRequestDispatcher.handle($0, using: vault) })

        let project = try remote.addProject(name: "App", icon: "folder")
        try remote.setActiveProject(id: project.id)
        XCTAssertEqual(try remote.activeProjectId(), project.id)

        _ = try remote.addEnvironment(name: "staging", projectId: project.id, color: "#123456")
        try remote.setActiveEnvironment(name: "staging", projectId: project.id)
        _ = try remote.add(name: "API_KEY", value: "dummy", description: nil, icon: nil, category: nil, projectId: project.id, environmentName: "staging")
        try remote.setAgentAccess(name: "API_KEY", projectId: project.id, policy: .blocked)
        XCTAssertEqual(try remote.secretCount(projectId: project.id, environmentName: "staging"), 1)
        XCTAssertEqual(try remote.totalSecretCount(projectId: project.id), 1)

        let exported = try remote.export(projectId: project.id, passphrase: "passphrase")
        XCTAssertEqual(try remote.decryptExport(exported, passphrase: "passphrase")["API_KEY"], "dummy")
        try remote.deleteProjectIncludingContents(id: project.id)
        XCTAssertNil(try remote.project(name: "App"))
    }
}
