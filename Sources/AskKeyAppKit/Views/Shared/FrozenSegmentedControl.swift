import AppKit
import SwiftUI
import AskKeyBroker
import AskKeyVault

struct FrozenSegmentedControl<Selection: Hashable>: View {
    let options: [(Selection, String)]
    @Binding var selection: Selection

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let active = selection == option.0
                Button {
                    selection = option.0
                } label: {
                    HStack(spacing: Theme.Spacing.xs) {
                        if active {
                            Image(systemName: "checkmark")
                                .font(Theme.Fonts.caption.bold())
                                .foregroundStyle(Theme.accent)
                        }
                        Text(option.1)
                            .lineLimit(1)
                    }
                    .font(Theme.Fonts.secondary.weight(active ? .semibold : .regular))
                    .foregroundStyle(active ? Theme.text : Theme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(active ? Theme.surface : Color.clear, in: .rect(cornerRadius: Theme.Radius.control))
                    .shadow(color: active ? Theme.cardShadow : .clear, radius: 2, x: 0, y: 1)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Theme.neutralSubtle, in: .rect(cornerRadius: 8))
    }
}
