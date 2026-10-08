import AskKeyBroker

/// Presentation only: the frozen summary remains the approval's source of truth.
struct FrozenWriteSummaryContent {
    struct Row: Equatable {
        let label: String?
        let values: [String]
    }

    let components: [Row]
    let instructions: [Row]
    let group: [Row]
    let createsGroup: Bool

    init(summary: BrokerCredentialWriteSummary) {
        let beforeComponents = summary.before.map(Self.componentText)
        let afterComponents = summary.after.map(Self.componentText)
        if beforeComponents.isEmpty && afterComponents.isEmpty {
            components = []
        } else {
            // Equal byte counts and delivery descriptors do not prove equal values.
            let unchanged = summary.before == summary.after && summary.beforeDigest != nil
                && summary.beforeDigest == summary.afterDigest
            components = Self.rows(operation: summary.operation, before: beforeComponents,
                after: afterComponents, unchanged: unchanged)
        }
        instructions = Self.rows(operation: summary.operation,
            before: [Self.instructionsText(summary.beforeUsageInstructions)],
            after: [Self.instructionsText(summary.afterUsageInstructions)],
            unchanged: (summary.beforeUsageInstructions ?? "") == (summary.afterUsageInstructions ?? ""))
        group = Self.rows(operation: summary.operation,
            before: [summary.beforeGroup ?? appLocalized("Ungrouped")],
            after: [summary.afterGroup ?? appLocalized("Ungrouped")],
            unchanged: summary.beforeGroup == summary.afterGroup)
        createsGroup = summary.createsGroup && (summary.operation == .create || summary.operation == .modify)
    }

    private static func rows(operation: BrokerApprovalOperation, before: [String],
        after: [String], unchanged: Bool) -> [Row] {
        switch operation {
        case .create:
            return after.isEmpty ? [] : [.init(label: nil, values: after)]
        case .delete, .read:
            return before.isEmpty ? [] : [.init(label: nil, values: before)]
        case .modify:
            if unchanged {
                return [.init(label: appLocalized("Unchanged"), values: before)]
            }
            return [.init(label: appLocalized("Before"), values: before),
                    .init(label: appLocalized("After"), values: after)]
        }
    }

    private static func instructionsText(_ value: String?) -> String {
        value.flatMap { $0.isEmpty ? nil : $0 } ?? appLocalized("None")
    }

    private static func componentText(_ item: BrokerCredentialComponentSummary) -> String {
        "\(item.name) · \(item.byteCount) B · \(item.delivery.environmentVariable ?? "App")"
    }
}
