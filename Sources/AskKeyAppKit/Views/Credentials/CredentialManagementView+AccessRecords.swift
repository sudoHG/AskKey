import AppKit
import SwiftUI
import AskKeyBroker
import AskKeyVault

extension CredentialManagementView {
    var accessRecordsDetail: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: appLocalized("Access records"), subtitle: FrozenAccessRecordsCopy.subtitle)
                .padding(.horizontal, Theme.Spacing.xxl)
                .padding(.top, Theme.Spacing.xxl)
                .padding(.bottom, Theme.Spacing.lg)

            if vault.credentialAccessRecords.isEmpty {
                WorkspaceEmptyState(
                    title: appLocalized("No Access Records Yet"),
                    message: FrozenAccessRecordsCopy.subtitle,
                    systemImage: "clock"
                )
            } else {
                let presentation = AccessRecordPresentation(
                    records: vault.credentialAccessRecords,
                    credentialName: credentialName(for:)
                )
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                        ForEach(presentation.sections, id: \.title) { section in
                            GroupedList(header: section.title) {
                                ForEach(Array(section.rows.enumerated()), id: \.element.id) { index, row in
                                    if index > 0 { GroupedListSeparator() }
                                    accessRecordRow(row)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.xxl)
                    .padding(.bottom, Theme.Spacing.xxl)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.windowBackground)
        .onAppear { if !previewMode { vault.reloadCredentialAccessRecords() } }
    }

    private func accessRecordRow(_ row: AccessRecordPresentation.Row) -> some View {
        // A record decided on this Mac keeps its single centered line; a
        // remote decision lines the time and result up with the sentence.
        HStack(alignment: row.detail == nil ? .center : .firstTextBaseline, spacing: Theme.Spacing.lg) {
            Text(row.time)
                .font(Theme.Fonts.secondary)
                .monospacedDigit()
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 40, alignment: .leading)
            if let detail = row.detail {
                VStack(alignment: .leading, spacing: 2) {
                    accessRecordSentence(row)
                    Text(verbatim: detail)
                        .font(Theme.Fonts.secondary)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } else {
                accessRecordSentence(row)
            }
            Spacer(minLength: Theme.Spacing.md)
            StatusLabel(title: row.resultTitle, role: row.resultRole)
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
        .accessibilityElement(children: .combine)
    }

    private func accessRecordSentence(_ row: AccessRecordPresentation.Row) -> some View {
        Text(row.sentence.plainText)
            .font(Theme.Fonts.body)
            .foregroundStyle(Theme.text)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private func credentialName(for id: String?) -> String {
        guard let id else { return appLocalized("Hidden credential request") }
        return vault.credentials.first { $0.id == id }?.name ?? id
    }

}
