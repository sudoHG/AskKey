import AskKeyDevices
import SwiftUI

/// “Codex” on “Studio Mac” wants to use “GitHub Token”, with the names
/// emphasized as on the Mac card. The names are shown in full and wrap, so
/// the credential always shows, however long the agent's name.
struct RequestSentence: View {
    let card: RequestCard

    var body: some View {
        Text("request.title \(RequestCopy.requester(card.display).bold()) \(Text(verbatim: card.macName).bold()) \(Text(verbatim: card.display.credentialName).bold())",
             bundle: .kit)
    }
}

/// The command on one line in a monospaced font, middle-truncated, as the
/// Mac card's subtitle.
struct RequestCommandSummary: View {
    let display: RequestDisplay

    var body: some View {
        Text(verbatim: display.commandSummary)
            .font(.footnote.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}

/// The Details row, which expands in place into a grouped list of every
/// field the request carries besides the sentence's names: requester and
/// purpose marked not verified, the credential, the full command, the
/// folder, the program, what is handed over and the Mac. The time left is
/// the page's footer. The fields are plain text, never links, and never
/// quoted or escaped again; none is a credential value.
struct RequestDetailsCard: View {
    let card: RequestCard
    var startsShown = false
    @State private var shown: Bool?

    private var isShown: Bool { shown ?? startsShown }
    private var display: RequestDisplay { card.display }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.snappy) { shown = !isShown }
            } label: {
                HStack(spacing: 12) {
                    Text("request.details", bundle: .kit)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .rotationEffect(.degrees(isShown ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .frame(minHeight: GroupedMetrics.rowMinHeight)
            }
            .buttonStyle(GroupedRowButtonStyle())
            .accessibilityValue(Text(isShown ? "request.details.expanded" : "request.details.collapsed", bundle: .kit))
            if isShown {
                rows
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: GroupedMetrics.cornerRadius, style: .continuous))
    }

    @ViewBuilder private var rows: some View {
        row("request.details.requestedBy", shortened: display.shortened.contains(.requesterName)) {
            Text("request.notVerified \(RequestCopy.requester(display))", bundle: .kit)
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
        row("request.details.mac") {
            Text("request.details.macValue \(Text(verbatim: card.macName)) \(card.macPairedAt, format: .dateTime.year().month().day())",
                 bundle: .kit)
        }
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

    /// One field: a divider, the label above the value, and the shortened
    /// note when the Mac shortened it. VoiceOver reads the three together.
    private func row<Value: View>(_ label: LocalizedStringKey, shortened: Bool = false,
                                  @ViewBuilder value: () -> Value) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            GroupedDivider()
            VStack(alignment: .leading, spacing: 3) {
                Text(label, bundle: .kit)
                    .font(.caption)
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .accessibilityElement(children: .combine)
        }
    }
}

/// The request page's words for the requester, buttons and problems.
enum RequestCopy {
    /// The requester's name, or "Local Agent" when the request names none.
    static func requester(_ display: RequestDisplay) -> Text {
        display.requesterName.isEmpty ? Text("request.localAgent", bundle: .kit) : Text(verbatim: display.requesterName)
    }

    static func buttonTitle(_ code: ApprovalDecisionCode, timedDuration: UInt64) -> Text {
        switch code {
        case .deny: return Text("request.deny", bundle: .kit)
        case .allowOnce: return Text("request.allowOnce", bundle: .kit)
        case .timedAllowance:
            if timedDuration % 60 == 0 {
                return Text("request.allowTimed \(String(timedDuration / 60))", bundle: .kit)
            }
            return Text("request.allowTimedDuration \(duration(timedDuration))", bundle: .kit)
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
