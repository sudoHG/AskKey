import Foundation
import AskKeyBroker

/// Shared wording for approval cards and the pending list. Names are quoted
/// with “ ” in both languages, as on the v0.2 card.
enum ApprovalCopy {
    static func requester(_ request: BrokerApprovalOperationRequest) -> String {
        request.callerName.flatMap { $0.isEmpty ? nil : $0 } ?? appLocalized("Local Agent")
    }

    static func quoted(_ name: String) -> String {
        "“" + name + "”"
    }

    static func group(_ name: String?) -> String {
        quoted(name ?? appLocalized("Ungrouped"))
    }

    static func bytes(_ count: Int) -> String {
        count == 1
            ? appLocalized("1 byte")
            : appLocalizedFormat("%@ bytes", count.formatted(.number.locale(AppLanguage.locale(for: AppLanguage.current))))
    }

    /// Rule-5 delivery wording; the variable name is the code argument.
    static func delivery(_ delivery: BrokerComponentDelivery) -> ApprovalLine {
        switch delivery {
        case .environmentVariable(let variable):
            return ApprovalLine(format: appLocalized("given to programs as environment variable %@"), code: [variable])
        case .temporaryFile(let variable):
            return ApprovalLine(format: appLocalized("given to programs as a temporary file (path in %@)"), code: [variable])
        case .none:
            return ApprovalLine(appLocalized("kept in Ask Key only, never given to agents"))
        }
    }

    /// "3 credentials (2 hidden from agents)"; the clause is omitted at zero.
    static func members(_ count: Int, hidden: Int) -> String {
        let members = count == 1
            ? appLocalizedFormat("%lld credential", count)
            : appLocalizedFormat("%lld credentials", count)
        return hidden > 0 ? appLocalizedFormat("%1$@ (%2$lld hidden from agents)", members, hidden) : members
    }

    static func sentences(_ parts: [String]) -> String {
        parts.joined(separator: appLocalized("Sentence separator"))
    }

    /// "A, B and C" in the current language.
    static func list(_ items: [String]) -> String {
        guard let last = items.last else { return "" }
        guard items.count > 1 else { return last }
        return appLocalizedFormat("%1$@ and %2$@", items.dropLast().joined(separator: appLocalized("List separator")), last)
    }

    /// Starts English text with a capital letter; Chinese is unchanged.
    static func capitalized(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }

    /// Names that the vault treats as the same item or group.
    static func matchKey(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}

/// One line of card text in which variable names render as code.
struct ApprovalLine: Equatable {
    struct Segment: Equatable {
        let text: String
        let code: Bool
    }

    let segments: [Segment]

    var plainText: String { segments.map(\.text).joined() }

    init(_ text: String) {
        segments = text.isEmpty ? [] : [Segment(text: text, code: false)]
    }

    /// Splits a localized `%@` format; arguments listed in `code` render as code.
    init(format: String, plain: [String] = [], code: [String] = []) {
        let arguments = plain + code
        segments = EmphasizedSentence(format: format, arguments: arguments).runs.map { run in
            Segment(text: run.text, code: run.argument.map { $0 >= plain.count } ?? false)
        }
    }

    private init(segments: [Segment]) { self.segments = segments }

    static func + (lhs: ApprovalLine, rhs: ApprovalLine) -> ApprovalLine {
        ApprovalLine(segments: lhs.segments + rhs.segments)
    }
}

/// Small status labels on neutral backgrounds in Details. Color carries risk,
/// not novelty.
enum ApprovalTag: Equatable {
    case unchanged, changed, new, newGroup, replaced, removed, noChange, merge

    var title: String {
        switch self {
        case .unchanged: return appLocalized("Unchanged")
        case .changed: return appLocalized("Changed")
        case .new: return appLocalized("New")
        case .newGroup: return appLocalized("New group tag")
        case .replaced: return appLocalized("Replaced")
        case .removed: return appLocalized("Removed")
        case .noChange: return appLocalized("No change")
        case .merge: return appLocalized("Merge")
        }
    }
}
