import AskKeyDevices
import SwiftUI

/// One request in the v0.2 card style: one sentence with a subject, one
/// subtitle line with the command summary, everything else under Details.
/// The fields are shown as plain text, never as links, and never quoted or
/// escaped again. Nothing on the card is a credential value.
struct RequestCardContent: View {
    let card: RequestCard
    let now: Date
    var isDeciding = false
    var problem: DecisionProblem?
    var showsDetails = false
    let onDecide: (ApprovalDecisionCode) -> Void
    let onDismiss: () -> Void

    @State private var detailsShown: Bool?

    private var phase: RequestPhase { card.phase(at: now) }
    private var display: RequestDisplay { card.display }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    RequestSentence(card: card)
                        .font(.title3)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(verbatim: display.commandSummary)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if phase.isFinished {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("common.dismiss", bundle: .kit))
                }
            }
            detailsToggle
            if detailsShown ?? showsDetails {
                RequestDetails(card: card, now: now)
            }
            if !phase.isFinished {
                buttons
            }
            status
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color(uiColor: .secondarySystemGroupedBackground)))
    }

    private var detailsToggle: some View {
        Button {
            detailsShown = !(detailsShown ?? showsDetails)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: (detailsShown ?? showsDetails) ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                Text("request.details", bundle: .kit)
                    .font(.subheadline.weight(.semibold))
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
    }

    /// Once a decision is stored, the other buttons are disabled and the
    /// chosen one stays marked; none of them does anything any more.
    @ViewBuilder private var buttons: some View {
        let chosen = card.decision
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                decisionButton(.deny, chosen: chosen, kind: .secondary)
                if display.offers.contains(.allowOnce) {
                    decisionButton(.allowOnce, chosen: chosen, kind: .primary)
                }
            }
            if display.offers.contains(.timedAllowance) {
                decisionButton(.timedAllowance, chosen: chosen, kind: .secondary)
            }
        }
        if chosen == nil {
            Text(display.offers == .denyOnly ? "request.denyOnly.footnote" : "request.allow.footnote", bundle: .kit)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func decisionButton(_ code: ApprovalDecisionCode, chosen: ApprovalDecisionCode?,
                                kind: ActionButtonStyle.Kind) -> some View {
        Button {
            if chosen == nil { onDecide(code) }
        } label: {
            HStack(spacing: 6) {
                if chosen == code { Image(systemName: "checkmark") }
                RequestCopy.buttonTitle(code, timedDuration: display.timedDuration)
            }
        }
        .buttonStyle(ActionButtonStyle(kind: kind))
        .disabled(isDeciding || (chosen != nil && chosen != code))
        .allowsHitTesting(chosen == nil)
        .accessibilityAddTraits(chosen == code ? .isSelected : [])
    }

    @ViewBuilder private var status: some View {
        if let problem, phase == .pending {
            NoticeCard(symbol: "exclamationmark.triangle.fill", tone: .warning, text: RequestCopy.problem(problem))
        }
        switch phase {
        case .pending:
            EmptyView()
        case .sending:
            NoticeCard(symbol: "arrow.up.circle", text: Text("request.state.sending \(Text(verbatim: card.macName))", bundle: .kit))
        case .waiting:
            NoticeCard(symbol: "hourglass", text: Text("request.state.waiting \(Text(verbatim: card.macName))", bundle: .kit))
        case .closed(let outcome):
            NoticeCard(symbol: RequestCopy.symbol(outcome), tone: RequestCopy.tone(outcome),
                       text: RequestCopy.outcome(outcome, macName: card.macName))
        case .timedOut:
            NoticeCard(symbol: "clock.badge.exclamationmark", tone: .warning, text: Text("request.outcome.timedOut", bundle: .kit))
        case .gone:
            NoticeCard(symbol: "arrow.clockwise.circle", tone: .warning,
                       text: Text("request.outcome.gone \(Text(verbatim: card.macName))", bundle: .kit))
        }
    }
}

/// “Codex” on “Studio Mac” wants to use “GitHub Token”, with the names
/// emphasized as on the Mac card.
struct RequestSentence: View {
    let card: RequestCard

    var body: some View {
        let requester = card.display.requesterName.isEmpty
            ? Text("request.localAgent", bundle: .kit) : Text(verbatim: card.display.requesterName)
        Text("request.title \(requester.bold()) \(Text(verbatim: card.macName).bold()) \(Text(verbatim: card.display.credentialName).bold())",
             bundle: .kit)
    }
}

/// Details: requester and purpose marked not verified, the full command,
/// the folder, the program, what is handed over, the time left and the Mac.
struct RequestDetails: View {
    let card: RequestCard
    let now: Date

    private var display: RequestDisplay { card.display }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            row("request.details.requestedBy", shortened: display.shortened.contains(.requesterName)) {
                let requester = display.requesterName.isEmpty
                    ? Text("request.localAgent", bundle: .kit) : Text(verbatim: display.requesterName)
                Text("request.notVerified \(requester)", bundle: .kit)
            }
            if !display.purpose.isEmpty {
                row("request.details.purpose", shortened: display.shortened.contains(.purpose)) {
                    Text("request.notVerified \(Text(verbatim: display.purpose))", bundle: .kit)
                }
            }
            row("request.details.credential", shortened: display.shortened.contains(.credentialName)) {
                Text(verbatim: display.credentialName)
            }
            row("request.details.command", shortened: display.shortened.contains(.commandLine)) {
                Text(verbatim: display.commandLine).font(.callout.monospaced())
            }
            if !display.workingDirectory.isEmpty {
                row("request.details.directory", shortened: display.shortened.contains(.workingDirectory)) {
                    Text(verbatim: display.workingDirectory).font(.callout.monospaced())
                }
            }
            row("request.details.program", shortened: display.shortened.contains(.executableName)) {
                Text(verbatim: display.executableName).font(.callout.monospaced())
            }
            row("request.details.handsOver", shortened: display.shortened.contains(.deliveryRows)) {
                handsOver
            }
            row("request.details.timeLeft") {
                let seconds = card.secondsLeft(at: now)
                let clock = String(format: "%d:%02d", seconds / 60, seconds % 60)
                if seconds > 0 {
                    Text("request.timeLeft.value \(clock)", bundle: .kit)
                } else {
                    Text("request.timeLeft.none", bundle: .kit)
                }
            }
            row("request.details.mac") {
                Text("request.details.macValue \(Text(verbatim: card.macName)) \(card.macPairedAt, format: .dateTime.year().month().day())",
                     bundle: .kit)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(uiColor: .tertiarySystemFill)))
    }

    @ViewBuilder private var handsOver: some View {
        if display.deliveryMetadataUnavailable {
            Text("request.handsOver.unavailable", bundle: .kit).foregroundStyle(.orange)
        } else if display.deliveryRows.isEmpty {
            Text("request.handsOver.nothing", bundle: .kit)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(display.deliveryRows.enumerated()), id: \.offset) { _, row in
                    let name = Text(verbatim: row.label.isEmpty ? display.credentialName : row.label)
                    let variable = Text(verbatim: row.variable).font(.callout.monospaced())
                    switch row.kind {
                    case .environmentVariable:
                        Text("request.handsOver.variable \(name) \(variable)", bundle: .kit)
                    case .temporaryFile:
                        Text("request.handsOver.file \(name) \(variable)", bundle: .kit)
                    }
                }
            }
        }
    }

    private func row<Value: View>(_ label: LocalizedStringKey, shortened: Bool = false,
                                  @ViewBuilder value: () -> Value) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label, bundle: .kit)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            value()
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            if shortened {
                Text("request.details.shortened", bundle: .kit)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The card's words for buttons, outcomes and problems.
enum RequestCopy {
    static func buttonTitle(_ code: ApprovalDecisionCode, timedDuration: UInt64) -> Text {
        switch code {
        case .deny: return Text("request.deny", bundle: .kit)
        case .allowOnce: return Text("request.allowOnce", bundle: .kit)
        case .timedAllowance:
            if timedDuration % 60 == 0 {
                let minutes = String(timedDuration / 60)
                return Text("request.allowTimed \(minutes)", bundle: .kit)
            }
            return Text("request.allowTimedDuration \(duration(timedDuration))", bundle: .kit)
        }
    }

    static func outcome(_ outcome: RequestOutcome, macName: String) -> Text {
        let mac = Text(verbatim: macName)
        switch outcome {
        case .allowedOnce: return Text("request.outcome.allowedOnce \(mac)", bundle: .kit)
        case .allowedTimed(let seconds): return Text("request.outcome.allowedTimed \(mac) \(duration(seconds))", bundle: .kit)
        case .denied: return Text("request.outcome.denied \(mac)", bundle: .kit)
        case .decidedOnMac: return Text("request.outcome.decidedOnMac", bundle: .kit)
        case .decidedElsewhere: return Text("request.outcome.decidedElsewhere", bundle: .kit)
        case .expired: return Text("request.outcome.expired", bundle: .kit)
        case .cancelled: return Text("request.outcome.cancelled", bundle: .kit)
        case .notApplied: return Text("request.outcome.notApplied", bundle: .kit)
        }
    }

    static func symbol(_ outcome: RequestOutcome) -> String {
        switch outcome {
        case .allowedOnce, .allowedTimed: return "checkmark.circle.fill"
        case .denied: return "xmark.circle.fill"
        case .decidedOnMac, .decidedElsewhere: return "info.circle.fill"
        case .expired: return "clock.fill"
        case .cancelled, .notApplied: return "exclamationmark.circle.fill"
        }
    }

    static func tone(_ outcome: RequestOutcome) -> NoticeCard.Tone {
        switch outcome {
        case .allowedOnce, .allowedTimed, .denied: return .success
        case .decidedOnMac, .decidedElsewhere: return .info
        case .expired, .cancelled, .notApplied: return .warning
        }
    }

    static func problem(_ problem: DecisionProblem) -> Text {
        switch problem {
        case .cancelled: return Text("request.problem.cancelled", bundle: .kit)
        case .failed: return Text("request.problem.failed", bundle: .kit)
        case .unavailable: return Text("request.problem.unavailable", bundle: .kit)
        case .account: return Text("request.problem.account", bundle: .kit)
        case .timeUp: return Text("request.problem.timeUp", bundle: .kit)
        case .storage: return Text("request.problem.storage", bundle: .kit)
        case .other: return Text("request.problem.other", bundle: .kit)
        }
    }

    /// Seconds in words, such as "30 minutes".
    static func duration(_ seconds: UInt64) -> Text {
        Text(Duration.seconds(Int64(seconds)), format: .units(allowed: [.hours, .minutes, .seconds], width: .wide))
    }
}

/// The cards, with the model's actions; the countdown redraws every second.
struct RequestList: View {
    let model: AppModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 14) {
                ForEach(model.requests) { card in
                    RequestCardView(model: model, card: card, now: context.date)
                }
            }
        }
    }
}

struct RequestCardView: View {
    let model: AppModel
    let card: RequestCard
    let now: Date

    var body: some View {
        RequestCardContent(card: card, now: now, isDeciding: model.decidingRequest != nil,
                           problem: model.decisionProblems[card.id],
                           onDecide: { code in Task { await model.decide(code, requestID: card.id) } },
                           onDismiss: { model.dismissRequest(id: card.id) })
    }
}

/// The request a tapped notification opened.
struct OpenedRequestView: View {
    let model: AppModel
    let id: String
    let onClose: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            OpenedRequestContent(card: model.requests.first { $0.id == id }, onClose: onClose) { card in
                RequestCardView(model: model, card: card, now: context.date)
            }
        }
        .screenScaffold()
    }
}

struct OpenedRequestContent<Card: View>: View {
    let card: RequestCard?
    let onClose: () -> Void
    @ViewBuilder var content: (RequestCard) -> Card

    var body: some View {
        ScreenContent(title: "request.sheet.title") {
            if let card {
                content(card)
            } else {
                NoticeCard(symbol: "tray", text: Text("request.sheet.gone", bundle: .kit))
            }
            Button(action: onClose) { Text("common.done", bundle: .kit) }
                .buttonStyle(ActionButtonStyle(kind: .secondary))
        }
    }
}
