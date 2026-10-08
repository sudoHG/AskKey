import SwiftUI
import AskKeyBroker

struct FrozenOrganizationSummaryContent {
    struct Row: Equatable {
        let title: String
        let detail: String?
    }

    let rows: [Row]

    init(summary: BrokerOrganizationSummary) {
        rows = summary.operations.enumerated().map { index, operation in
            let title: String
            let detail: String?
            switch operation {
            case .move(let credential, let from, let to):
                title = appLocalizedFormat("Move %@: %@ → %@", credential,
                    from ?? appLocalized("Ungrouped"), to ?? appLocalized("Ungrouped"))
                detail = nil
            case .createGroup(let name):
                title = appLocalizedFormat("Create group “%@”", name)
                detail = appLocalized("New group — created when approved")
            case .renameGroup(let from, let to, let members, let nonvisible):
                title = appLocalizedFormat("Rename group “%@” → “%@”", from, to)
                detail = appLocalizedFormat("%lld credentials, %lld not visible to agents", members, nonvisible)
            case .deleteGroup(let name, let members, let nonvisible):
                title = appLocalizedFormat("Delete group “%@”", name)
                detail = appLocalizedFormat("%lld credentials, %lld not visible to agents", members, nonvisible)
            }
            return .init(title: String(index + 1) + ". " + title, detail: detail)
        }
    }
}

/// All operations remain readable by scrolling; actions stay outside the cap.
struct FrozenOrganizationApprovalContent: View {
    let summary: BrokerOrganizationSummary?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(appLocalized("Proposed organization"))
                .font(Theme.Fonts.caption.weight(.semibold))
            if let summary {
                let rows = FrozenOrganizationSummaryContent(summary: summary).rows
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                                Text(verbatim: row.title)
                                    .foregroundStyle(Theme.text)
                                if let detail = row.detail {
                                    Text(verbatim: detail).foregroundStyle(Theme.textSecondary)
                                }
                            }
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .font(Theme.Fonts.caption)
                    .textSelection(.enabled)
                }
                .frame(maxHeight: 210)
                .accessibilityIdentifier("approval-organization-operations")
            }
        }
    }
}
