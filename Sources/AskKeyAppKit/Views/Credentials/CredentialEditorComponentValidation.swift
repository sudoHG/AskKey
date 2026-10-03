import AppKit
import SwiftUI
import AskKeyBroker
import AskKeyVault

enum CredentialEditorComponentValidation {
    static func canSave(_ components: [CredentialComponentDraft]) -> Bool {
        let retained = components.filter { !isOmittable($0) }
        return !retained.isEmpty && retained.allSatisfy(isComplete)
    }

    static func inputs(_ components: [CredentialComponentDraft]) -> [CredentialComponentInput]? {
        guard canSave(components) else { return nil }
        var inputs: [CredentialComponentInput] = []
        for component in components where !isOmittable(component) {
            let name = component.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if component.kind == .file {
                guard let file = component.file else { return nil }
                inputs.append(.init(
                    name: name,
                    value: .file(filename: file.originalFilename, bytes: file.bytes),
                    delivery: component.delivery ?? .temporaryFile(name),
                    masked: component.masked
                ))
            } else {
                inputs.append(.init(name: name, value: .text(component.text), delivery: component.delivery ?? .environmentVariable(name), masked: component.masked))
            }
        }
        return inputs
    }

    private static func isComplete(_ component: CredentialComponentDraft) -> Bool {
        !component.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (component.kind == .file ? component.file != nil : !component.text.isEmpty)
    }

    private static func isEmpty(_ component: CredentialComponentDraft) -> Bool {
        component.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && component.text.isEmpty
            && component.file == nil
    }

    private static func isOmittable(_ component: CredentialComponentDraft) -> Bool {
        if isEmpty(component) { return true }
        guard case .omitWhenNameIs(let expectedName) = component.emptyValuePolicy else {
            return false
        }
        return component.name.trimmingCharacters(in: .whitespacesAndNewlines) == expectedName
            && component.text.isEmpty
            && component.file == nil
    }
}
