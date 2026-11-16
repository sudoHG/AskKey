import AskKeyDevices
import SwiftUI

/// A tapped notification's page before the app verified its request
/// (#348): a placeholder without content while it loads, and a page each
/// for a request that could not be fetched, has ended or could not be
/// verified. Nothing here comes from the notification, whose text the app
/// has not verified (ADR 0014 → iPhone app, Opening a notification); the
/// Mac's name on the ended page is this iPhone's own name for it.
struct OpeningPage: View {
    let phase: OpeningPhase
    /// False in the first 0.3 seconds: only the page's frame shows.
    var showsPlaceholder = true
    /// Renders pass false: `ImageRenderer` cannot draw a scroll view, the
    /// accessibility focus or the shimmer's animation.
    var scrolls = true
    var onRetry: () -> Void = {}
    var onViewHistory: () -> Void = {}
    let onClose: () -> Void
    @Environment(\.locale) private var locale

    var body: some View {
        content
            .onChange(of: phase) { _, phase in
                // Loading again after Try Again, and slow; the pages after
                // them move VoiceOver to their titles.
                let announcement: String.LocalizationValue? = switch phase {
                case .loading: "request.opening.loading"
                case .slow: "request.opening.slow"
                case .failed, .ended, .unverified: nil
                }
                if let announcement {
                    AccessibilityNotification.Announcement(String(localized: announcement, bundle: .kit, locale: locale))
                        .post()
                }
            }
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .loading, .slow:
            OpeningPlaceholder(isSlow: phase == .slow, isVisible: showsPlaceholder, animates: scrolls,
                               scrolls: scrolls, onClose: onClose)
        case .failed:
            OpeningStatePage(symbol: "wifi.exclamationmark", color: .orange,
                             title: Text("request.opening.failed.title", bundle: .kit),
                             detail: Text("request.opening.failed.detail", bundle: .kit),
                             scrolls: scrolls, onClose: onClose) {
                Button(action: onRetry) {
                    Text("request.opening.retry", bundle: .kit)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .buttonBorderShape(.capsule)
                closeButton
            }
        case .ended(let ended):
            OpeningStatePage(symbol: EndedCopy.symbol(ended), color: EndedCopy.color(ended),
                             title: Text("request.opening.ended.title", bundle: .kit),
                             detail: EndedCopy.sentence(ended), scrolls: scrolls, onClose: onClose) {
                Button(action: onViewHistory) {
                    Text("request.opening.viewHistory", bundle: .kit)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.accentColor)
                .controlSize(.large)
                .buttonBorderShape(.capsule)
                closeButton
            }
        case .unverified:
            OpeningStatePage(symbol: "shield.slash", color: .orange,
                             title: Text("request.opening.unverified.title", bundle: .kit),
                             detail: Text("request.opening.unverified.detail", bundle: .kit),
                             scrolls: scrolls, onClose: onClose) {
                closeButton
            }
        }
    }

    private var closeButton: some View {
        Button(action: onClose) {
            NeutralButtonLabel { Text("common.close", bundle: .kit) }
        }
        .neutralActionStyle()
    }
}

/// The request page's shape without content, shimmering: the key, two bars
/// for the sentence, one for the subtitle and one for a button, with what
/// the app is doing below.
private struct OpeningPlaceholder: View {
    let isSlow: Bool
    let isVisible: Bool
    let animates: Bool
    let scrolls: Bool
    let onClose: () -> Void
    @ScaledMetric(relativeTo: .title) private var keyCircle: CGFloat = 52
    @ScaledMetric(relativeTo: .title2) private var lineHeight: CGFloat = 22
    @ScaledMetric(relativeTo: .subheadline) private var subtitleHeight: CGFloat = 14
    @ScaledMetric(relativeTo: .body) private var buttonHeight: CGFloat = 50

    var body: some View {
        RequestSheetLayout(scrolls: scrolls, onClose: onClose) {
            if isVisible {
                VStack(alignment: .leading, spacing: 18) {
                    Image(systemName: "key")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: keyCircle, height: keyCircle)
                        .background(Circle().fill(Color(uiColor: .secondarySystemGroupedBackground)))
                    VStack(alignment: .leading, spacing: 10) {
                        bar(width: 1, height: lineHeight)
                        bar(width: 0.62, height: lineHeight)
                        bar(width: 0.45, height: subtitleHeight)
                            .padding(.top, 4)
                    }
                }
                .modifier(Shimmer(isActive: animates))
                .accessibilityHidden(true)
            }
        } actions: {
            if isVisible {
                Capsule()
                    .fill(Color(uiColor: .systemFill))
                    .frame(height: buttonHeight)
                    .modifier(Shimmer(isActive: animates))
                    .accessibilityHidden(true)
                VStack(spacing: 6) {
                    Text(status, bundle: .kit)
                        .font(.subheadline)
                    Text(footnote, bundle: .kit)
                        .font(.footnote)
                }
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var status: LocalizedStringKey {
        isSlow ? "request.opening.slow" : "request.opening.loading"
    }

    private var footnote: LocalizedStringKey {
        isSlow ? "request.opening.slow.footnote" : "request.opening.loading.footnote"
    }

    /// A rounded bar `width` of the available width wide.
    private func bar(width: CGFloat, height: CGFloat) -> some View {
        GeometryReader { proxy in
            RoundedRectangle(cornerRadius: height / 2, style: .continuous)
                .fill(Color(uiColor: .systemFill))
                .frame(width: proxy.size.width * width)
        }
        .frame(height: height)
    }
}

/// A highlight sweeping across the placeholder's shapes, never with Reduce
/// Motion. Renders draw the still shapes.
private struct Shimmer: ViewModifier {
    let isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var swept = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if isActive && !reduceMotion {
                    GeometryReader { proxy in
                        LinearGradient(colors: [.clear, .white.opacity(0.6), .clear], startPoint: .leading,
                                       endPoint: .trailing)
                            .frame(width: proxy.size.width * 0.6)
                            .offset(x: swept ? proxy.size.width : -proxy.size.width * 0.6)
                    }
                    .mask(content)
                    .allowsHitTesting(false)
                    .onAppear {
                        withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { swept = true }
                    }
                    .onDisappear { swept = false }
                }
            }
    }
}

/// A page in the outcome page's shape: a large symbol in its color, a
/// title, one sentence, and the actions.
private struct OpeningStatePage<Actions: View>: View {
    let symbol: String
    let color: Color
    let title: Text
    let detail: Text
    let scrolls: Bool
    let onClose: () -> Void
    @ViewBuilder var actions: Actions
    @ScaledMetric(relativeTo: .largeTitle) private var symbolSize: CGFloat = 64

    var body: some View {
        RequestSheetLayout(scrolls: scrolls, onClose: onClose) {
            VStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: symbolSize))
                    .foregroundStyle(color)
                    .padding(.bottom, 8)
                    .accessibilityHidden(true)
                title
                    .font(.title.bold())
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .modifier(FocusedOnAppear(isEnabled: scrolls))
                detail
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 40)
        } actions: {
            actions
        }
    }
}

/// How an ended request ended, in one sentence for each ending of the
/// outcome page (#347), or the generic one when the app does not know.
/// The Mac's name is bold, as on the outcome page.
enum EndedCopy {
    /// The outcome page's symbol; a tray when the ending is unknown.
    static func symbol(_ ended: EndedRequest?) -> String {
        ended?.ending.symbol ?? "tray.fill"
    }

    /// The outcome page's color; gray when the ending is unknown.
    static func color(_ ended: EndedRequest?) -> Color {
        (ended?.ending.tone ?? .neutral).color
    }

    static func sentence(_ ended: EndedRequest?) -> Text {
        guard let ended else { return Text("request.opening.ended.unknown", bundle: .kit) }
        let mac = Text(verbatim: RequestCopy.short(ended.macName)).bold()
        switch ended.ending {
        case .closed(.allowedOnce): return Text("request.opening.ended.allowedOnce \(mac)", bundle: .kit)
        case .closed(.allowedTimed(let seconds)):
            return Text("request.opening.ended.allowedTimed \(RequestCopy.duration(seconds)) \(mac)", bundle: .kit)
        case .closed(.denied): return Text("request.opening.ended.denied \(mac)", bundle: .kit)
        case .closed(.decidedOnMac): return Text("request.opening.ended.onMac \(mac)", bundle: .kit)
        case .closed(.decidedElsewhere): return Text("request.opening.ended.elsewhere", bundle: .kit)
        case .closed(.expired): return Text("request.opening.ended.expired", bundle: .kit)
        case .closed(.cancelled): return Text("request.opening.ended.cancelled", bundle: .kit)
        case .closed(.notApplied): return Text("request.opening.ended.notApplied", bundle: .kit)
        case .timedOut: return Text("request.opening.ended.timedOut \(mac)", bundle: .kit)
        case .gone: return Text("request.opening.ended.gone \(mac)", bundle: .kit)
        }
    }
}

/// Re-evaluates a tapped request's page when it changes by itself: the
/// placeholder at 0.3 seconds, slow at 3 and failed at 15.
struct OpeningSchedule: TimelineSchedule {
    let changes: [Date]

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> [Date] {
        [startDate] + changes.filter { $0 > startDate }
    }
}
