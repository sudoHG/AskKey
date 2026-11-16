import AskKeyDevices
import SwiftUI

/// A request's page, opened from its row or a tapped notification, as a
/// sheet over every tab (ADR 0014 → iPhone app, amended by #345).
struct OpenedRequestView: View {
    let model: AppModel
    let id: String
    let onClose: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            OpenedRequestContent(card: model.requests.first { $0.id == id },
                                 opening: model.opening?.id == id ? model.openingPhase(at: context.date) : nil,
                                 now: context.date, biometry: model.biometryKind,
                                 isDeciding: model.decidingRequest != nil, problem: model.decisionProblems[id],
                                 onDecide: { code in Task { await model.decide(code, requestID: id) } },
                                 onClose: onClose)
        }
    }
}

/// The sheet's content: the request page while the request can be decided
/// or waits for the Mac, its outcome page once it ended, and, before the
/// app verified a tapped request itself, a loading or unavailable state
/// that shows nothing from the notification.
struct OpenedRequestContent: View {
    let card: RequestCard?
    var opening: OpeningPhase?
    let now: Date
    var biometry: BiometryKind = .faceID
    var isDeciding = false
    var problem: DecisionProblem?
    var showsDetails = false
    /// Renders pass false: `ImageRenderer` cannot draw a scroll view.
    var scrolls = true
    let onDecide: (ApprovalDecisionCode) -> Void
    let onClose: () -> Void

    var body: some View {
        if let card {
            if let ending = card.phase(at: now).ending {
                RequestOutcomePage(card: card, ending: ending, scrolls: scrolls, onClose: onClose)
            } else {
                RequestPage(card: card, now: now, biometry: biometry, isDeciding: isDeciding, problem: problem,
                            showsDetails: showsDetails, scrolls: scrolls, onDecide: onDecide, onClose: onClose)
            }
        } else {
            RequestSheetLayout(scrolls: scrolls, onClose: onClose) {
                if let opening {
                    OpeningCard(phase: opening)
                } else {
                    NoticeCard(symbol: "tray", text: Text("request.sheet.gone", bundle: .kit))
                }
            } actions: {
                Button(action: onClose) {
                    NeutralButtonLabel { Text("common.done", bundle: .kit) }
                }
                .neutralActionStyle()
            }
        }
    }
}

/// The page's frame: a close button and the title Request at the top, the
/// content, and the actions pinned to the bottom. The content scrolls in
/// the app; at accessibility text sizes the actions scroll with it, so they
/// never cover it.
struct RequestSheetLayout<Content: View, Actions: View>: View {
    var scrolls = true
    var closeHint: LocalizedStringKey?
    let onClose: () -> Void
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(spacing: 0) {
            header
            if typeSize.isAccessibilitySize {
                scrolling {
                    VStack(spacing: 28) {
                        content
                        actionStack
                    }
                }
            } else {
                scrolling { content }
                actionStack
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
    }

    private var header: some View {
        HStack {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color(uiColor: .secondarySystemGroupedBackground)))
                    .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("common.close", bundle: .kit))
            .accessibilityHint(closeHint.map { Text($0, bundle: .kit) } ?? Text(verbatim: ""))
            Spacer(minLength: 0)
        }
        .overlay {
            Text("request.sheet.title", bundle: .kit)
                .font(.headline)
                .lineLimit(1)
                .padding(.horizontal, 60)
                .accessibilityAddTraits(.isHeader)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    private var actionStack: some View {
        VStack(spacing: 12) { actions }
    }

    @ViewBuilder private func scrolling<Inner: View>(@ViewBuilder _ inner: () -> Inner) -> some View {
        let padded = inner()
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        if scrolls {
            ScrollView { padded }
                .scrollBounceBehavior(.basedOnSize)
        } else {
            padded.frame(maxHeight: .infinity, alignment: .top)
        }
    }
}

/// The page of a request that can still be decided or waits for the Mac,
/// in the Mac card's shape: a key, the sentence, the command on one line,
/// Details, the actions and the time left.
struct RequestPage: View {
    let card: RequestCard
    let now: Date
    var biometry: BiometryKind = .faceID
    var isDeciding = false
    var problem: DecisionProblem?
    var showsDetails = false
    var scrolls = true
    let onDecide: (ApprovalDecisionCode) -> Void
    let onClose: () -> Void
    @ScaledMetric(relativeTo: .title) private var keyCircle: CGFloat = 52

    var body: some View {
        RequestSheetLayout(scrolls: scrolls, closeHint: "request.close.hint", onClose: onClose) {
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: "key")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: keyCircle, height: keyCircle)
                    .background(Circle().fill(Color(uiColor: .secondarySystemGroupedBackground)))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 8) {
                    RequestSentence(card: card)
                        .font(.title2)
                        .fixedSize(horizontal: false, vertical: true)
                    RequestCommandSummary(display: card.display)
                }
                RequestDetailsCard(card: card, startsShown: showsDetails)
            }
        } actions: {
            RequestActions(card: card, now: now, biometry: biometry, isDeciding: isDeciding, problem: problem,
                           onDecide: onDecide)
        }
    }
}

/// The page's bottom: a note when there is one, the buttons in the Mac
/// card's order, what happens to a decision, and the time left. Allow Once
/// is the prominent button and the timed allowance the tinted one, both
/// with the Face ID or Touch ID symbol; Deny is gray, without a symbol.
/// Once a decision is stored only the chosen button stays, disabled.
struct RequestActions: View {
    let card: RequestCard
    let now: Date
    var biometry: BiometryKind = .faceID
    var isDeciding = false
    var problem: DecisionProblem?
    let onDecide: (ApprovalDecisionCode) -> Void

    private var phase: RequestPhase { card.phase(at: now) }
    private var display: RequestDisplay { card.display }

    var body: some View {
        if phase == .pending {
            notes
        }
        ForEach(card.pageButtons(at: now), id: \.self) { code in
            button(code)
        }
        status
        ExpiryFooter(secondsLeft: card.secondsLeft(at: now))
            .padding(.top, 4)
    }

    @ViewBuilder private var notes: some View {
        if let problem {
            NoticeCard(symbol: "exclamationmark.circle.fill", tone: .warning, text: RequestCopy.problem(problem))
        }
        if card.isChecking {
            NoticeCard(symbol: "hourglass", tone: .neutral, text: Text("request.state.checking", bundle: .kit))
        }
        if let note = Self.denyOnlyNote(display) {
            NoticeCard(symbol: "exclamationmark.circle.fill", tone: .neutral, text: Text(note, bundle: .kit))
        }
    }

    /// Why a request offers only Deny: the run will be refused anyway, or a
    /// field was shortened, so only the Mac shows the whole request.
    static func denyOnlyNote(_ display: RequestDisplay) -> LocalizedStringKey? {
        guard display.offers == .denyOnly else { return nil }
        return display.deliveryMetadataUnavailable ? "request.handsOver.unavailable" : "request.denyOnly.shortened"
    }

    @ViewBuilder private func button(_ code: ApprovalDecisionCode) -> some View {
        let enabled = phase == .pending && !isDeciding && !card.isChecking
        let base = Button {
            onDecide(code)
        } label: {
            label(code)
        }
        .disabled(!enabled)
        .accessibilityAddTraits(card.decision == code ? .isSelected : [])
        switch code {
        case .allowOnce:
            base.buttonStyle(.borderedProminent)
                .controlSize(.large)
                .buttonBorderShape(.capsule)
                .accessibilityHint(allowHint)
        case .timedAllowance:
            base.buttonStyle(.bordered)
                .tint(.accentColor)
                .controlSize(.large)
                .buttonBorderShape(.capsule)
                .accessibilityHint(allowHint)
        case .deny:
            base.neutralActionStyle()
        }
    }

    @ViewBuilder private func label(_ code: ApprovalDecisionCode) -> some View {
        let title = RequestCopy.buttonTitle(code, timedDuration: display.timedDuration)
        if code == .deny {
            NeutralButtonLabel { title }
        } else {
            Label { title } icon: { Image(systemName: biometry.symbol) }
                .frame(maxWidth: .infinity)
        }
    }

    private var allowHint: Text {
        Text(biometry == .touchID ? "request.allow.hint.touchID" : "request.allow.hint.faceID", bundle: .kit)
    }

    @ViewBuilder private var status: some View {
        switch phase {
        case .sending:
            HStack(spacing: 8) {
                SendingIndicator()
                Text("request.state.sending \(Text(verbatim: card.macName))", bundle: .kit)
            }
            .statusLine()
        case .waiting:
            Label {
                Text("request.state.waiting \(Text(verbatim: card.macName))", bundle: .kit)
            } icon: {
                Image(systemName: "arrow.up.circle")
            }
            .statusLine()
        default:
            EmptyView()
        }
    }
}

private extension View {
    func statusLine() -> some View {
        font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
    }
}

/// "This request expires in 4:32", orange under a minute, as the Mac card's footer.
struct ExpiryFooter: View {
    let secondsLeft: Int
    @Environment(\.locale) private var locale

    var body: some View {
        Label {
            Text("request.expiresIn \(RequestRow.clock(secondsLeft))", bundle: .kit)
        } icon: {
            Image(systemName: "clock")
        }
        .font(.footnote)
        .monospacedDigit()
        .foregroundStyle(secondsLeft < 60 ? Color.orange : Color.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("request.expiresIn \(RequestRow.spoken(secondsLeft, locale: locale))", bundle: .kit))
        .accessibilityAddTraits(.updatesFrequently)
    }
}

/// The system's activity indicator while a decision is being sent. iOS 18's
/// symbol form is drawn by SwiftUI, so it also shows in renders.
private struct SendingIndicator: View {
    var body: some View {
        Group {
            if #available(iOS 18, *) {
                Image(systemName: "progress.indicator")
                    .symbolEffect(.variableColor.iterative)
            } else {
                ProgressView()
            }
        }
        .accessibilityHidden(true)
    }
}

/// A neutral button's title: full width, in the primary label color, and
/// secondary while disabled.
struct NeutralButtonLabel<Title: View>: View {
    @ViewBuilder var title: Title
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        title
            .frame(maxWidth: .infinity)
            .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
    }
}

extension View {
    /// Deny and Done: a large gray bordered capsule.
    func neutralActionStyle() -> some View {
        buttonStyle(.bordered)
            .tint(Color(uiColor: .systemGray))
            .controlSize(.large)
            .buttonBorderShape(.capsule)
    }
}

extension BiometryKind {
    /// The symbol on the Allow buttons.
    var symbol: String {
        switch self {
        case .faceID: return "faceid"
        case .touchID: return "touchid"
        }
    }
}

/// The tapped request before its card, in the card's shape: one sentence
/// with a subject and one subtitle line.
struct OpeningCard: View {
    let phase: OpeningPhase

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: phase == .loading ? "hourglass" : "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(phase == .loading ? Color.accentColor : Color.orange)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 6) {
                Text(title, bundle: .kit)
                    .font(.title3)
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle, bundle: .kit)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color(uiColor: .secondarySystemGroupedBackground)))
        .accessibilityElement(children: .combine)
    }

    private var title: LocalizedStringKey {
        phase == .loading ? "request.opening.title" : "request.opening.failed.title"
    }

    private var subtitle: LocalizedStringKey {
        phase == .loading ? "request.opening.subtitle" : "request.opening.failed.subtitle"
    }
}
