import AskKeyDevices
import SwiftUI

/// A request's page, opened from its row or a tapped notification, as a
/// sheet over every tab (ADR 0014 → iPhone app, amended by #345).
struct OpenedRequestView: View {
    let model: AppModel
    let id: String
    let onClose: () -> Void
    /// The last card this page showed. Once the request ended, its outcome
    /// stays after the stored request expires, until the person closes the
    /// page (decision 7 of #344); a request that can still be decided is
    /// never shown from it.
    @State private var lastCard: RequestCard?

    var body: some View {
        let live = model.requests.first { $0.id == id }
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let card = live ?? lastCard.flatMap { $0.phase(at: context.date).isFinished ? $0 : nil }
            if card == nil, let opening = model.opening, opening.id == id {
                // Before the card, the page also changes at 0.3, 3 and 15
                // seconds; Try Again starts them over.
                TimelineView(OpeningSchedule(changes: opening.changeDates)) { moment in
                    content(card: nil, at: moment.date)
                }
                .id(opening.since)
            } else {
                content(card: card, at: context.date)
            }
        }
        .onChange(of: live, initial: true) { previous, card in
            if let card { lastCard = card }
            // The verified card replaced a page shown before it (#348).
            if previous == nil, card != nil {
                UIAccessibility.post(notification: .screenChanged, argument: nil)
            }
        }
    }

    private func content(card: RequestCard?, at date: Date) -> some View {
        OpenedRequestContent(card: card, opening: card == nil && model.opening?.id == id ? model.openingPhase(at: date) : nil,
                             showsPlaceholder: model.openingShowsPlaceholder(at: date),
                             now: date, biometry: model.biometryKind,
                             isDeciding: model.decidingRequest != nil, isDecidingHere: model.decidingRequest == id,
                             problem: model.decisionProblems[id],
                             savedToHistory: card.map { model.isSavedToHistory($0) } ?? false,
                             onRetry: { Task { await model.retryOpening() } },
                             onViewHistory: { model.showHistory() },
                             onDecide: { code in Task { await model.decide(code, requestID: id) } },
                             onClose: onClose)
    }
}

/// The sheet's content: the request page while the request can be decided
/// or waits for the Mac, its outcome page once it ended, and, before the
/// app verified a tapped request itself, the opening pages (#348), which
/// show nothing from the notification.
struct OpenedRequestContent: View {
    let card: RequestCard?
    var opening: OpeningPhase?
    /// False in the first 0.3 seconds of loading.
    var showsPlaceholder = true
    let now: Date
    var biometry: BiometryKind = .faceID
    /// A decision is being checked and stored, for this or another request.
    var isDeciding = false
    var isDecidingHere = false
    /// The button tapped before the page appeared; only renders set it.
    var tapped: ApprovalDecisionCode?
    var problem: DecisionProblem?
    var showsDetails = false
    /// The ended request's History entry was written (#349).
    var savedToHistory = false
    /// Renders pass false: `ImageRenderer` cannot draw a scroll view.
    var scrolls = true
    var onRetry: () -> Void = {}
    var onViewHistory: () -> Void = {}
    let onDecide: (ApprovalDecisionCode) -> Void
    let onClose: () -> Void

    var body: some View {
        if let card {
            if let ending = card.phase(at: now).ending {
                RequestOutcomePage(card: card, ending: ending, savedToHistory: savedToHistory, scrolls: scrolls,
                                   onClose: onClose)
            } else {
                RequestPage(card: card, now: now, biometry: biometry, isDeciding: isDeciding,
                            isDecidingHere: isDecidingHere, tapped: tapped, problem: problem,
                            showsDetails: showsDetails, scrolls: scrolls, onDecide: onDecide, onClose: onClose)
            }
        } else if let opening {
            OpeningPage(phase: opening, showsPlaceholder: showsPlaceholder, scrolls: scrolls, onRetry: onRetry,
                        onViewHistory: onViewHistory, onClose: onClose)
        } else {
            RequestSheetLayout(scrolls: scrolls, onClose: onClose) {
                NoticeCard(symbol: "tray", text: Text("request.sheet.gone", bundle: .kit))
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
/// the app. Above the default text size the actions scroll after the
/// content instead, so they never cover the sentence: Allow is never on
/// screen while the credential's name is not.
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
            if !Self.pinsActions(at: typeSize) {
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

    /// The actions stay at the bottom only up to the default text size.
    static func pinsActions(at typeSize: DynamicTypeSize) -> Bool {
        typeSize <= .large
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
    var isDecidingHere = false
    var tapped: ApprovalDecisionCode?
    var problem: DecisionProblem?
    var showsDetails = false
    var scrolls = true
    let onDecide: (ApprovalDecisionCode) -> Void
    let onClose: () -> Void
    @ScaledMetric(relativeTo: .title) private var keyCircle: CGFloat = 52

    /// Closing decides later only while nothing was chosen yet.
    private var closeHint: LocalizedStringKey? {
        card.phase(at: now) == .pending && !isDecidingHere ? "request.close.hint" : nil
    }

    var body: some View {
        RequestSheetLayout(scrolls: scrolls, closeHint: closeHint, onClose: onClose) {
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
            RequestActions(card: card, now: now, biometry: biometry, isDeciding: isDeciding,
                           isDecidingHere: isDecidingHere, problem: problem, onDecide: onDecide, tapped: tapped)
        }
    }
}

/// The page's bottom: a note when there is one, the buttons in the Mac
/// card's order, what happens to a decision, and the time left. Allow Once
/// is the prominent button and the timed allowance the tinted one, both
/// with the Face ID or Touch ID symbol; Deny is gray, without a symbol.
/// From the tap, while the app checks and stores the decision, only the
/// tapped button stays, disabled, with a spinner; once the decision is
/// stored, only the chosen one, with what happens to it.
struct RequestActions: View {
    let card: RequestCard
    let now: Date
    var biometry: BiometryKind = .faceID
    var isDeciding = false
    var isDecidingHere = false
    var problem: DecisionProblem?
    let onDecide: (ApprovalDecisionCode) -> Void
    /// The button last tapped on this page.
    @State var tapped: ApprovalDecisionCode?

    private var phase: RequestPhase { card.phase(at: now) }
    private var display: RequestDisplay { card.display }

    var body: some View {
        if phase == .pending && !isDecidingHere {
            notes
        }
        ForEach(card.pageButtons(at: now, tapped: isDecidingHere ? tapped : nil), id: \.self) { code in
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
        if display.deliveryMetadataUnavailable { return "request.handsOver.unavailable" }
        return display.shortened.isEmpty ? "request.denyOnly.other" : "request.denyOnly.shortened"
    }

    @ViewBuilder private func button(_ code: ApprovalDecisionCode) -> some View {
        let enabled = phase == .pending && !isDeciding && !card.isChecking
        let base = Button {
            tapped = code
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
        case .pending where isDeciding:
            // Checking and storing a decision, here or on another request's page.
            HStack(spacing: 8) {
                SendingIndicator()
                Text("request.state.busy", bundle: .kit)
            }
            .statusLine()
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
                Image(systemName: "hourglass")
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
