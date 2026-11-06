import SwiftUI

extension View {
    /// A menu picker keeps showing the selected item's old title
    /// when a language switch changes the item titles but not the selection
    /// (#266). A new identity per language rebuilds the control, so the
    /// displayed title follows Ask Key's language.
    func rebuildsOnLanguageChange() -> some View {
        modifier(LanguageRefreshingIdentity())
    }
}

private struct LanguageRefreshingIdentity: ViewModifier {
    func body(content: Content) -> some View {
        content.id(AppLanguage.store.resolved)
    }
}
