import SwiftUI
import AskKeyBroker

/// Each grant has one row, even when it covers several credentials.
struct FrozenTimedAllowanceList: View {
    let allowances: [BrokerTimedAllowance]
    let now: Date
    let revoke: (UUID) -> Void

    var body: some View {
        if !allowances.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Text(appLocalized("Timed allowances")).font(Theme.Fonts.caption.weight(.semibold))
                    .foregroundStyle(Theme.textTertiary)
                ForEach(allowances) { allowance in
                    HStack(alignment: .top, spacing: Theme.Spacing.md) {
                        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                            Text(verbatim: allowance.groupName ?? allowance.members.first?.name ?? "")
                                .font(Theme.Fonts.body.weight(.semibold)).foregroundStyle(Theme.text)
                            if allowance.groupName != nil {
                                ForEach(allowance.members, id: \.credentialID) { member in
                                    Text(verbatim: member.name).font(Theme.Fonts.secondary).foregroundStyle(Theme.textSecondary)
                                }
                            }
                            Text(appLocalized("Timed allow remaining ") + FrozenCountdown.format(deadline: allowance.expiresAt, now: now))
                                .font(Theme.Fonts.caption).foregroundStyle(Theme.textSecondary).monospacedDigit()
                        }
                        Spacer()
                        Button(appLocalized(allowance.groupName == nil ? "Revoke Now" : "Revoke Group Allowance")) {
                            revoke(allowance.id)
                        }
                        .accessibilityIdentifier("timed-allowance-revoke-\(allowance.id)")
                    }
                }
            }
            .padding(Theme.Spacing.lg)
            .background(Theme.surface, in: .rect(cornerRadius: Theme.Radius.group))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.group).stroke(Theme.neutral(0.08)))
            .accessibilityIdentifier("timed-allowance-list")
        }
    }
}
