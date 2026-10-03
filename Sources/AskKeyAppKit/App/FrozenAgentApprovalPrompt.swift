import SwiftUI
import AskKeyBroker

struct FrozenAgentApprovalPrompt: View {
    let request: BrokerApprovalOperationRequest
    var trustedCredentialName: String? = nil
    var expiresAt: Date? = nil
    let timedAllowanceEnabled: Bool
    var timedAllowanceMinutes: Int = 30
    var writeSummary: BrokerCredentialWriteSummary? = nil
    var revealMaterial: (@MainActor () async throws -> FrozenApprovalMaterial)? = nil
    let finish: (BrokerApprovalDecision?) -> Void
    @State private var revealedMaterial: FrozenApprovalMaterial?
    @State private var revealing = false
    @State private var revealFailed = false
    @State private var revealTask: Task<Void, Never>?

    private var caller: String { request.callerName ?? appLocalized("Local Agent") }
    private var credential: String { trustedCredentialName ?? request.credentialName ?? request.targetID }
    private var operationTitle: String {
        switch request.operation {
        case .read: return appLocalizedFormat("%@ requests to use a credential", caller)
        case .create: return appLocalizedFormat("%@ requests to create a credential", caller)
        case .modify: return appLocalizedFormat("%@ requests to modify a credential", caller)
        case .delete: return appLocalizedFormat("%@ requests to delete a credential", caller)
        }
    }

    var body: some View {
        let _ = AppLanguage.store.resolved
        VStack(spacing: 10) {
            Text(appLocalized("Brand monogram"))
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(Theme.brand.gradient, in: .rect(cornerRadius: 11))
            Text(appLocalized("ASK KEY · AGENT REQUEST"))
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Theme.textMuted)
            Text(operationTitle)
                .font(.system(size: 14.5, weight: .bold))
            VStack(alignment: .leading, spacing: 7) {
                approvalRow(appLocalized("Caller"), caller, badge: appLocalized("Declared · Unverified"))
                approvalRow(appLocalized("Credential"), credential)
                if let purpose = request.callerPurpose, !purpose.isEmpty {
                    approvalRow(appLocalized("Purpose"), purpose)
                }
                if request.operation == .delete {
                    approvalRow(appLocalized("Destination"), appLocalized("Recycle Bin · Recoverable for 30 days"))
                }
            }
            .padding(11)
            .background(Theme.neutral(0.055), in: .rect(cornerRadius: 10))
            Text(appLocalized("Caller identity is self-declared and unverified. Decide from the credential and purpose."))
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let writeSummary {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(appLocalized("Before"))
                        ForEach(Array(writeSummary.before.enumerated()), id: \.offset) { _, item in
                            Text("\(item.name) · \(item.byteCount) B · \(item.delivery.environmentVariable ?? "App")")
                        }
                        Text(appLocalized("After"))
                        ForEach(Array(writeSummary.after.enumerated()), id: \.offset) { _, item in
                            Text("\(item.name) · \(item.byteCount) B · \(item.delivery.environmentVariable ?? "App")")
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.font(.system(size: 10)).frame(maxHeight: 70)
            }
            if request.operation != .read {
                VStack(alignment: .leading, spacing: 6) {
                    Text(appLocalized("Frozen Content to Write"))
                        .font(.system(size: 11, weight: .semibold))
                    if let revealedMaterial {
                        HStack {
                            Text(revealedMaterial.title).lineLimit(1)
                            Spacer()
                            Text(revealedMaterial.encoding).foregroundStyle(Theme.textMuted)
                            Button(appLocalized("Hide")) { self.revealedMaterial = nil }
                        }.font(.system(size: 10))
                        ScrollView {
                            Text(verbatim: revealedMaterial.content)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(height: 85)
                    } else {
                        HStack {
                            Text("••••••••").foregroundStyle(Theme.textMuted)
                            Spacer()
                            Button(appLocalized("Authenticate and View")) {
                                guard let revealMaterial, !revealing else { return }
                                revealing = true
                                revealFailed = false
                                revealTask = Task {
                                    defer { revealing = false }
                                    do {
                                        let material = try await revealMaterial()
                                        guard !Task.isCancelled else { return }
                                        revealedMaterial = material
                                    } catch {
                                        if !Task.isCancelled { revealFailed = true }
                                    }
                                }
                            }
                            .disabled(revealMaterial == nil || revealing)
                            .accessibilityIdentifier("approval-reveal-frozen-material")
                        }
                        Text(appLocalized("Viewing requires separate authentication and does not approve this request."))
                            .font(.system(size: 10)).foregroundStyle(Theme.textMuted)
                    }
                    if revealFailed {
                        Text(appLocalized("Unable to view: authentication was not completed or the request is no longer valid."))
                            .font(.system(size: 10)).foregroundStyle(Theme.red)
                    }
                }
                .padding(10)
                .background(Theme.neutral(0.055), in: .rect(cornerRadius: 8))
            }
            VStack(spacing: 7) {
                Button { finish(.once) } label: {
                    Text(primaryTitle)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Theme.brand, in: .rect(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("approval-allow-once")
                if request.operation == .read, timedAllowanceEnabled {
                    Button {
                        finish(.timedAllow(duration: nil))
                    } label: {
                        VStack(spacing: 1) {
                            Text(appLocalizedFormat("Allow for %lld Minutes", timedAllowanceMinutes))
                            Text(appLocalized("Applies to all local callers for this credential · Revocable anytime"))
                                .font(.system(size: 10)).foregroundStyle(Theme.textMuted)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(Color.white, in: .rect(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.sep))
                    }
                    .buttonStyle(.plain)
                }
                Button { finish(.deny) } label: {
                    Text(appLocalized("Deny"))
                        .foregroundStyle(Theme.red)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("approval-deny")
            }
            .frame(maxWidth: .infinity)
            HStack {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(appLocalized("Remaining ") + FrozenCountdown.format(deadline: expiresAt, now: context.date))
                }
                Spacer()
                Button(appLocalized("Press ESC to Decide Later")) { finish(nil) }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
            }
            .font(.system(size: 10.5))
            .foregroundStyle(Theme.textMuted)
        }
        .padding(20)
        .background(.ultraThinMaterial)
        .environment(\.locale, AppLanguage.store.locale)
        .onDisappear { revealTask?.cancel(); revealTask = nil; revealedMaterial = nil }
    }

    private var primaryTitle: String {
        switch request.operation {
        case .read: return appLocalized("Allow Once")
        case .create: return appLocalized("Approve Creation")
        case .modify: return appLocalized("Approve Change")
        case .delete: return appLocalized("Approve Deletion")
        }
    }

    private func approvalRow(_ label: String, _ value: String, badge: String? = nil) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label).foregroundStyle(Theme.textMuted).frame(width: 44, alignment: .leading)
            Text(value).fontWeight(.medium)
            if let badge {
                Text(badge)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Theme.amber)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Theme.amber.opacity(0.13), in: .rect(cornerRadius: 4))
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
    }
}
