import Foundation
@testable import AskKeyAppKit

/// Isolated replay of the ef90 Agent access appear path.
/// The control flow is copied from ef90, not from the current View.
/// Production code is not reverted.
enum EF90AgentAccessAppearReplay {
    struct Gate {
        private var generations: [AgentClient: Int] = [:]

        mutating func begin(_ client: AgentClient) -> Int? {
            if generations[client] != nil { return nil }
            let generation = 1
            generations[client] = generation
            return generation
        }

        mutating func complete(_ client: AgentClient, generation: Int) -> Bool {
            guard generations[client] == generation else { return false }
            generations[client] = nil
            return true
        }
    }

    @MainActor
    static func appear(
        previewMode: Bool = false,
        checkedClients: Set<AgentClient> = [],
        vault: VaultViewModel,
        preview: @escaping @Sendable (AgentClient) throws -> AgentClientPreview
    ) async {
        // Former ef90 auto-preview control flow with a retained-client fixture.
        if !previewMode && !checkedClients.contains(.cursor) {
            await previewClient(.cursor, vault: vault, preview: preview)
        }
    }

    @MainActor
    static func previewClient(
        _ client: AgentClient,
        vault: VaultViewModel,
        preview: @escaping @Sendable (AgentClient) throws -> AgentClientPreview
    ) async {
        // Verbatim ef90 `previewClient`, with the load closure supplied by the
        // caller so the replay can inject a spy/stub without touching production.
        var gate = Gate()
        guard let generation = gate.begin(client) else { return }
        // Verbatim ef90 `loadAgentClientPreview` — preview failure writes global error.
        let loaded: AgentClientPreview?
        do {
            loaded = try await Task.detached {
                try preview(client)
            }.value
        } catch {
            vault.errorMessage = AgentClientErrorCopy.message(for: client, error: error)
            loaded = nil
        }
        guard loaded != nil else {
            _ = gate.complete(client, generation: generation)
            return
        }
        _ = gate.complete(client, generation: generation)
    }
}
