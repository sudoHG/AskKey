import SwiftUI
@testable import AskKeyiOSKit

/// iOS draws the navigation bar and the tab bar itself, so `ImageRenderer`
/// cannot capture them. These stand-ins lay out what the system shows
/// around a tab's real content, with the tabs' own names and symbols, for
/// the wording and layout review: the large title, the optional **+**, and
/// the tab bar with the Requests badge. The content is laid out as
/// `tabScaffold()` lays it out in its scroll view: at least as tall as the
/// visible area between the bars, and taller when it needs to be, which
/// makes a taller image.
struct TabScreenStandIn<Content: View>: View {
    /// An iPhone screen's height without the status bar, the navigation bar
    /// with its large title, and the tab bar.
    static var visibleHeight: CGFloat { 852 - 147 - 90 }

    let tab: HomeTab
    var badge = 0
    var showsAdd = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                if showsAdd {
                    Image(systemName: "plus")
                        .font(.title3.weight(.medium))
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(Color(uiColor: .systemBackground)))
                        .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
                }
            }
            .frame(height: 44)
            .padding(.horizontal, 16)
            .padding(.top, 54)
            Text(tab.title, bundle: .kit)
                .font(.largeTitle.bold())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            content
                .frame(maxWidth: .infinity, minHeight: Self.visibleHeight, alignment: .top)
                .fixedSize(horizontal: false, vertical: true)
            TabBarStandIn(selected: tab, badge: badge)
                .padding(.horizontal, 24)
                .padding(.bottom, 28)
        }
    }
}

/// The tab bar as iOS draws it: three tabs in a capsule, the selected one
/// tinted and filled, the Requests tab with its badge.
private struct TabBarStandIn: View {
    let selected: HomeTab
    let badge: Int

    var body: some View {
        HStack(spacing: 0) {
            ForEach(HomeTab.allCases, id: \.self) { tab in
                VStack(spacing: 3) {
                    Image(systemName: tab.symbol)
                        .symbolVariant(.fill)
                        .font(.system(size: 20, weight: .medium))
                        .frame(height: 26)
                        .overlay(alignment: .topTrailing) {
                            if tab == .requests, badge > 0 {
                                Text(verbatim: String(badge))
                                    .font(.caption2.bold())
                                    .foregroundStyle(.white)
                                    .frame(minWidth: 18, minHeight: 18)
                                    .background(Circle().fill(.red))
                                    .offset(x: 10, y: -6)
                            }
                        }
                    Text(tab.title, bundle: .kit)
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(tab == selected ? Color.accentColor : Color.primary)
                .frame(maxWidth: .infinity, minHeight: 54)
                .background(Capsule().fill(tab == selected ? Color(uiColor: .systemFill) : .clear).padding(4))
            }
        }
        .padding(4)
        .background(Capsule().fill(Color(uiColor: .systemBackground)))
        .shadow(color: .black.opacity(0.1), radius: 12, y: 4)
    }
}

/// A screen pushed in a tab's navigation, with the system's back button
/// and the tab bar, which stays visible.
struct PushedScreenStandIn<Content: View>: View {
    var tab: HomeTab = .macs
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "chevron.backward")
                    .font(.title3.weight(.medium))
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color(uiColor: .systemBackground)))
                    .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
                Spacer()
            }
            .frame(height: 44)
            .padding(.horizontal, 16)
            .padding(.top, 54)
            .padding(.bottom, 8)
            content
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            TabBarStandIn(selected: tab, badge: 0)
                .padding(.horizontal, 24)
                .padding(.bottom, 28)
        }
        .frame(minHeight: 852, alignment: .top)
    }
}

/// A sheet as iOS draws it at full height: the status bar over the dimmed
/// screen behind, then the sheet's rounded top, with room for the home
/// indicator below the page's actions. A page that fits is as tall as the
/// screen; a tall one grows to its content, as scrolling would show it.
struct SheetStandIn<Content: View>: View {
    var tall = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            Color(uiColor: .systemGray3).frame(height: 62)
            content
                .padding(.bottom, 22)
                .frame(maxWidth: .infinity, maxHeight: tall ? nil : .infinity, alignment: .top)
                .fixedSize(horizontal: false, vertical: tall)
                .background(Color(uiColor: .systemGroupedBackground))
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 38, topTrailingRadius: 38, style: .continuous))
                .background(Color(uiColor: .systemGray3))
        }
        .frame(height: tall ? nil : 852)
    }
}
