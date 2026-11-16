import AskKeyDevices
import SwiftUI

/// The request page once the request ended (decisions 3 and 7 of #344): a
/// large symbol whose color tells Allow from Deny at a glance, a title, one
/// sentence on what it means, a summary of the request and Done. It shows
/// until the person taps Done or closes the sheet.
struct RequestOutcomePage: View {
    let card: RequestCard
    let ending: RequestEnding
    var scrolls = true
    let onClose: () -> Void
    @ScaledMetric(relativeTo: .largeTitle) private var symbolSize: CGFloat = 64

    var body: some View {
        RequestSheetLayout(scrolls: scrolls, onClose: onClose) {
            VStack(spacing: 24) {
                VStack(spacing: 10) {
                    Image(systemName: ending.symbol)
                        .font(.system(size: symbolSize))
                        .foregroundStyle(ending.tone.color)
                        .padding(.bottom, 8)
                        .accessibilityHidden(true)
                    OutcomeCopy.title(ending)
                        .font(.title.bold())
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                        .modifier(FocusedOnAppear(isEnabled: scrolls))
                    OutcomeCopy.sentence(ending, card: card)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 6) {
                    RequestSentence(card: card)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    RequestCommandSummary(display: card.display)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(RoundedRectangle(cornerRadius: GroupedMetrics.cornerRadius, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground)))
                .accessibilityElement(children: .combine)
            }
            .padding(.top, 40)
        } actions: {
            Button(action: onClose) {
                NeutralButtonLabel { Text("common.done", bundle: .kit) }
            }
            .neutralActionStyle()
        }
    }
}

/// The outcome replaced the buttons VoiceOver was on, so VoiceOver moves to
/// the title. Only in the app: `ImageRenderer` cannot draw the focus
/// wrapper, which would take the page's free space in a render.
private struct FocusedOnAppear: ViewModifier {
    let isEnabled: Bool
    @AccessibilityFocusState private var focused: Bool

    func body(content: Content) -> some View {
        if isEnabled {
            content
                .accessibilityFocused($focused)
                .onAppear { focused = true }
        } else {
            content
        }
    }
}

extension EndingTone {
    var color: Color {
        switch self {
        case .allowed: return .green
        case .denied: return .red
        case .neutral: return Color(uiColor: .systemGray)
        case .attention: return .orange
        }
    }
}

/// The outcome page's title and sentence for each ending. The Mac's name is
/// this iPhone's own name for it; the allowed-timed wording uses the
/// duration the Mac reported.
enum OutcomeCopy {
    static func title(_ ending: RequestEnding) -> Text {
        switch ending {
        case .closed(.allowedOnce): return Text("request.ending.allowedOnce.title", bundle: .kit)
        case .closed(.allowedTimed(let seconds)):
            if seconds % 60 == 0 {
                return Text("request.ending.allowedTimed.title \(String(seconds / 60))", bundle: .kit)
            }
            return Text("request.ending.allowedTimedDuration.title \(RequestCopy.duration(seconds))", bundle: .kit)
        case .closed(.denied): return Text("request.ending.denied.title", bundle: .kit)
        case .closed(.decidedOnMac): return Text("request.ending.decidedOnMac.title", bundle: .kit)
        case .closed(.decidedElsewhere): return Text("request.ending.decidedElsewhere.title", bundle: .kit)
        case .closed(.expired): return Text("request.ending.expired.title", bundle: .kit)
        case .closed(.cancelled): return Text("request.ending.cancelled.title", bundle: .kit)
        case .closed(.notApplied): return Text("request.ending.notApplied.title", bundle: .kit)
        case .timedOut: return Text("request.ending.timedOut.title", bundle: .kit)
        case .gone: return Text("request.ending.gone.title", bundle: .kit)
        }
    }

    static func sentence(_ ending: RequestEnding, card: RequestCard) -> Text {
        let mac = Text(verbatim: card.macName)
        let credential = Text(verbatim: card.display.credentialName)
        switch ending {
        case .closed(.allowedOnce):
            return Text("request.ending.allowedOnce \(RequestCopy.requester(card.display)) \(credential) \(mac)", bundle: .kit)
        case .closed(.allowedTimed(let seconds)):
            return Text("request.ending.allowedTimed \(RequestCopy.duration(seconds)) \(mac) \(credential)", bundle: .kit)
        case .closed(.denied): return Text("request.ending.denied \(credential) \(mac)", bundle: .kit)
        case .closed(.decidedOnMac): return Text("request.ending.decidedOnMac \(mac)", bundle: .kit)
        case .closed(.decidedElsewhere): return Text("request.ending.decidedElsewhere", bundle: .kit)
        case .closed(.expired): return Text("request.ending.expired", bundle: .kit)
        case .closed(.cancelled): return Text("request.ending.cancelled", bundle: .kit)
        case .closed(.notApplied): return Text("request.ending.notApplied", bundle: .kit)
        case .timedOut: return Text("request.ending.timedOut \(mac)", bundle: .kit)
        case .gone: return Text("request.ending.gone \(mac)", bundle: .kit)
        }
    }
}
