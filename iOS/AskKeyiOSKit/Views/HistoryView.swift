import SwiftUI

/// The History tab (ADR 0014 → iPhone app, History, amended by #345). Until
/// the app keeps a history (#349), it shows only its empty state.
struct HistoryView: View {
    var body: some View {
        HistoryContent()
            .tabScaffold()
            .navigationTitle(Text(HomeTab.history.title, bundle: .kit))
            .navigationBarTitleDisplayMode(.large)
    }
}

/// The History tab's content, drawn by SwiftUI alone so it renders for review.
struct HistoryContent: View {
    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            EmptyStateView(symbol: "clock.arrow.circlepath", title: "history.empty.title", detail: "history.empty.detail")
            Spacer(minLength: 24)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 24)
    }
}
