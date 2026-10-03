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
                    HStack(spacing: 4) {
                        if active {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Theme.brand)
                        }
                        Text(option.1)
                            .lineLimit(1)
                    }
                    .font(.system(size: 11.5, weight: active ? .semibold : .regular))
                    .foregroundStyle(active ? Theme.text : Theme.textMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(active ? Color.white : Color.clear, in: .rect(cornerRadius: 6))
                    .shadow(color: active ? Theme.cardShadow : .clear, radius: 2, x: 0, y: 1)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Theme.neutral(0.06), in: .rect(cornerRadius: 8))
    }
}
