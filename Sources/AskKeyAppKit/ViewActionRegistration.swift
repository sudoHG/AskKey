import SwiftUI

/// An optional action sink supplied by a view's host. Ordinary app views have none.
package struct ViewActionRegistration {
    let register: (String, @escaping () -> Void) -> Void

    package init(register: @escaping (String, @escaping () -> Void) -> Void) {
        self.register = register
    }
}

private struct ViewActionRegistrationKey: EnvironmentKey {
    static let defaultValue: ViewActionRegistration? = nil
}

extension EnvironmentValues {
    package var viewActionRegistration: ViewActionRegistration? {
        get { self[ViewActionRegistrationKey.self] }
        set { self[ViewActionRegistrationKey.self] = newValue }
    }
}

private struct ActionRegistrationModifier: ViewModifier {
    @Environment(\.viewActionRegistration) private var registration
    let identifier: String
    let action: () -> Void

    func body(content: Content) -> some View {
        content.onAppear { registration?.register(identifier, action) }
    }
}

extension View {
    func registerAction(_ identifier: String, action: @escaping () -> Void) -> some View {
        modifier(ActionRegistrationModifier(identifier: identifier, action: action))
    }
}
