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
        HStack(spacing: Theme.Spacing.lg) {
            Text(row.time)
                .font(Theme.Fonts.secondary)
                .monospacedDigit()
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 40, alignment: .leading)
            Text(row.sentence.plainText)
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: Theme.Spacing.md)
            StatusLabel(title: row.resultTitle, role: row.resultRole)
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
        .accessibilityElement(children: .combine)
    }

    private func credentialName(for id: String?) -> String {
        guard let id else { return appLocalized("Hidden credential request") }
        return vault.credentials.first { $0.id == id }?.name ?? id
    }

}
