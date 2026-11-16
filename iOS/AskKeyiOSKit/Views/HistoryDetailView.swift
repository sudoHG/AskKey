import SwiftUI

/// One History entry (ADR 0014 → iPhone app, History, amended by #345),
/// pushed from its row without Face ID or Touch ID. It closes by itself
/// when the entry goes, for example after **Clear All History**.
struct HistoryDetailView: View {
    let model: AppModel
    let entryID: String
    @Environment(\.dismiss) private var dismiss

    private var entry: HistoryEntry? { model.history.first { $0.id == entryID } }

    var body: some View {
        Group {
            if let entry {
                HistoryDetailContent(entry: entry, biometry: model.biometryKind)
            }
        }
        .screenScaffold()
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: entry == nil) { _, gone in
            if gone { dismiss() }
        }
    }
}

/// The detail's content, drawn by SwiftUI alone so it renders for review:
/// the outcome page's symbol, color and title, who decided where, the
/// request's names, when it arrived and ended, and what the iPhone does not
/// keep.
struct HistoryDetailContent: View {
    let entry: HistoryEntry
    var biometry: BiometryKind = .faceID
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone
    @ScaledMetric(relativeTo: .largeTitle) private var symbolSize: CGFloat = 56

    var body: some View {
        VStack(spacing: 24) {
            if let ending = entry.ending {
                header(ending)
            }
            GroupedSection {
                ValueRow {
                    Text("request.details.requestedBy", bundle: .kit)
                } value: {
                    Text("request.notVerified \(HistoryCopy.requester(entry, shortened: false))", bundle: .kit)
                        .foregroundStyle(.secondary)
                }
                GroupedDivider()
                ValueRow {
                    Text("request.details.credential", bundle: .kit)
                } value: {
                    Text(verbatim: entry.credentialName).foregroundStyle(.secondary)
                }
                GroupedDivider()
                ValueRow {
                    Text("request.details.program", bundle: .kit)
                } value: {
                    Text(verbatim: entry.executableName).font(.body.monospaced()).foregroundStyle(.secondary)
                }
                GroupedDivider()
                ValueRow {
                    Text("request.details.mac", bundle: .kit)
                } value: {
                    Text(verbatim: entry.macName).foregroundStyle(.secondary)
                }
            }
            GroupedSection {
                ValueRow {
                    Text("history.received", bundle: .kit)
                } value: {
                    Text(verbatim: format(entry.receivedAt)).foregroundStyle(.secondary)
                }
                GroupedDivider()
                ValueRow {
                    Text("history.ended", bundle: .kit)
                } value: {
                    Text(verbatim: entry.endedAt.map(format) ?? "").foregroundStyle(.secondary)
                }
            } footer: {
                Text("history.detail.footer", bundle: .kit)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private func header(_ ending: RequestEnding) -> some View {
        VStack(spacing: 10) {
            Image(systemName: ending.symbol)
                .font(.system(size: symbolSize))
                .foregroundStyle(ending.tone.color)
                .padding(.bottom, 4)
                .accessibilityHidden(true)
            OutcomeCopy.title(ending)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            HistoryCopy.decidedWhere(entry, ending: ending, biometry: biometry)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .frame(maxWidth: .infinity)
    }

    /// The date and time with seconds, on this iPhone's clock.
    private func format(_ date: Date) -> String {
        var style = Date.FormatStyle.dateTime.year().month(.abbreviated).day().hour().minute().second()
        style.locale = locale
        style.timeZone = timeZone
        return date.formatted(style)
    }
}

extension HistoryCopy {
    /// Who decided where: this iPhone for its own Allow or Deny, otherwise
    /// the outcome page's sentence, with the Mac's name as the entry keeps it.
    static func decidedWhere(_ entry: HistoryEntry, ending: RequestEnding, biometry: BiometryKind) -> Text {
        let mac = Text(verbatim: RequestCopy.short(entry.macName)).bold()
        switch ending {
        case .closed(.allowedOnce), .closed(.allowedTimed):
            return Text(biometry == .touchID ? "history.by.allowed.touchID" : "history.by.allowed", bundle: .kit)
        case .closed(.denied): return Text("history.by.denied", bundle: .kit)
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
