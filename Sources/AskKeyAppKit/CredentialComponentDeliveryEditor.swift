import SwiftUI
import AskKeyCore

struct CredentialComponentDeliveryEditor: View {
    @Binding var component: CredentialComponentDraft

    private var choice: Binding<Int> {
        Binding(get: {
            switch component.delivery {
            case nil: 0
            case .environmentVariable: 1
            case .temporaryFile: 2
            case .none?: 3
            }
        }, set: { value in
            let name = component.delivery?.environmentVariable ?? component.name
            switch value {
            case 1: component.delivery = .environmentVariable(name)
            case 2: component.delivery = .temporaryFile(name)
            case 3: component.delivery = CredentialComponentDelivery.none
            default: component.delivery = nil
            }
        })
    }

    private var variableName: Binding<String> {
        Binding(get: { component.delivery?.environmentVariable ?? component.name }, set: { value in
            if case .temporaryFile = component.delivery { component.delivery = .temporaryFile(value) }
            else { component.delivery = .environmentVariable(value) }
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(component.name).fontWeight(.medium)
                Spacer()
                Picker(appLocalized("Delivery"), selection: choice) {
                    Text(appLocalized("Use Item Name")).tag(0)
                    if component.kind != .file {
                        Text(appLocalized("Environment Variable")).tag(1)
                    }
                    Text(appLocalized("Temporary File Path")).tag(2)
                    Text(appLocalized("Keep in App Only")).tag(3)
                }.labelsHidden().frame(width: 180)
            }
            if choice.wrappedValue == 1 || choice.wrappedValue == 2 {
                TextField(appLocalized("Delivery Environment Variable"), text: variableName)
                    .textFieldStyle(.roundedBorder)
            }
        }.padding(.vertical, 4)
    }
}

struct FrozenImportedValue: View {
    let value: String
    @State private var revealed = false

    var body: some View {
        HStack {
            Text(verbatim: revealed ? value : "••••••••")
                .font(.system(size: 12.5, design: .monospaced))
                .lineLimit(2)
            Spacer()
            Button(revealed ? appLocalized("Hide") : appLocalized("View")) {
                revealed.toggle()
            }.buttonStyle(.plain)
        }
    }
}
