import SwiftUI
import AskKeyVault

enum BackupImportCopy {
    static func date(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = AppLanguage.locale(for: AppLanguage.current)
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    static func credentials(_ count: Int) -> String {
        AppLanguage.localizedCount("%lld credentials", oneKey: "%lld credential", count: count,
                                   language: AppLanguage.current)
    }

    static func skippedCount(_ plan: BackupImportPlan) -> Int {
        plan.skippedIdentical.count + plan.skippedInRecycleBin.count + plan.skippedRecycled.count
    }

    static func resultSummary(_ result: BackupImportResult) -> String {
        result.additions.isEmpty
            ? appLocalized("No credentials were added.")
            : appLocalizedFormat("Added %@ to this library.", credentials(result.additions.count))
    }
}

/// What an import would do: counts, every final renamed name, the backup's
/// credentials whose identical copy is in this Recycle Bin, and skipped
/// recycled credentials.
struct BackupImportPreviewContent: View {
    let plan: BackupImportPlan

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            if plan.additions.isEmpty && plan.createdGroups.isEmpty {
                BackupNotice(text: appLocalized("Everything in this backup is already in this library. There is nothing to import."),
                             isWarning: false)
            }
            GroupedList {
                countRow(appLocalized("Will be added"), plan.additions.count)
                GroupedListSeparator()
                countRow(appLocalized("Will be renamed"), plan.renamed.count)
                GroupedListSeparator()
                countRow(appLocalized("Will be skipped"), BackupImportCopy.skippedCount(plan))
            }
            BackupNameLists(lists: lists)
            Text(appLocalized("Nothing in this library is deleted or overwritten. Credentials set to Allow arrive as Ask every time, and Hidden ones stay Hidden."))
                .font(Theme.Fonts.secondary)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var lists: [BackupNameList] {
        [
            BackupNameList(
                id: "renamed",
                title: appLocalized("Renamed, because a different credential already has the name:"),
                names: plan.renamed.map(\.name)
            ),
            BackupNameList(
                id: "recycle-bin",
                title: appLocalized("Already in your Recycle Bin. Restore them there instead of importing a copy:"),
                names: plan.skippedInRecycleBin.map(\.name)
            ),
            BackupNameList(
                id: "skipped-recycled",
                title: appLocalized("Not imported from the backup's Recycle Bin, because the name is taken or 30 days have passed:"),
                names: plan.skippedRecycled
            ),
            BackupNameList(id: "groups", title: appLocalized("New groups:"), names: plan.createdGroups),
        ].filter { !$0.names.isEmpty }
    }

    private func countRow(_ title: String, _ count: Int) -> some View {
        HStack {
            Text(title)
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.text)
            Spacer(minLength: Theme.Spacing.md)
            Text(BackupImportCopy.credentials(count))
                .font(Theme.Fonts.body)
                .foregroundStyle(count == 0 ? Theme.textTertiary : Theme.text)
                .monospacedDigit()
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.sm)
    }
}

/// What a committed import added: every renamed name and new group.
struct BackupImportResultContent: View {
    let result: BackupImportResult

    var body: some View {
        BackupNameLists(lists: [
            BackupNameList(
                id: "renamed",
                title: appLocalized("Renamed so you can compare them with the credentials already here:"),
                names: result.renamed.map(\.name)
            ),
            BackupNameList(id: "groups", title: appLocalized("New groups:"), names: result.createdGroups),
        ].filter { !$0.names.isEmpty })
    }
}

struct BackupNameList: Identifiable {
    let id: String
    let title: String
    let names: [String]
}

/// Titled lists of names. Long lists scroll inside a bounded height so the
/// sheet stays within the window.
struct BackupNameLists: View {
    let lists: [BackupNameList]
    private static let unscrolledRowLimit = 6

    var body: some View {
        if lists.map(\.names.count).reduce(0, +) > Self.unscrolledRowLimit {
            ScrollView { content }
                .frame(height: BackupSheetMetrics.listMaxHeight)
        } else if !lists.isEmpty {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            ForEach(lists) { list in
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text(list.title)
                        .font(Theme.Fonts.secondary.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(Array(list.names.enumerated()), id: \.offset) { _, name in
                        Text(name)
                            .font(Theme.Fonts.body)
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(name)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("backup-list-\(list.id)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
