import SwiftUI
import UIKit

/// The pairing sheet: scanner, pairing code, and the outcome.
struct PairingFlowView: View {
    let model: PairingFlowModel
    let onClose: () -> Void

    var body: some View {
        content
            .screenScaffold()
            .interactiveDismissDisabled(model.isSessionOpen)
            .task { await model.prepareCamera() }
            .task { await model.run() }
    }

    @ViewBuilder private var content: some View {
        switch model.stage {
        case .scanning, .sending:
            ScannerContent(camera: model.camera, problem: model.scanProblem, isSending: model.stage == .sending,
                           onDismissProblem: model.dismissScanProblem, onCancel: onClose) {
                QRScannerView { text in Task { await model.handleScanned(text) } }
            }
        case .waitingForCode:
            PairingCodeContent(display: nil, isConfirming: false, problem: nil, onConfirm: {}, onCancel: onClose)
        case .code(let display):
            PairingCodeContent(display: display, isConfirming: model.isConfirming, problem: model.confirmProblem,
                               onConfirm: { Task { await model.confirm() } }, onCancel: onClose)
        case .paired(let name):
            PairingResultContent(outcome: .paired(macName: name), onDone: onClose)
        case .failed(let failure):
            PairingResultContent(outcome: .failed(failure), onDone: onClose)
        }
    }
}

/// The QR scanner. It says to scan only the code in Ask Key on the
/// person's own Mac, never one someone sends.
struct ScannerContent<Preview: View>: View {
    let camera: CameraAccess
    let problem: ScanProblem?
    let isSending: Bool
    let onDismissProblem: () -> Void
    let onCancel: () -> Void
    @ViewBuilder var preview: Preview

    var body: some View {
        ScreenContent(title: "scanner.title") {
            NoticeCard(symbol: "qrcode.viewfinder", tone: .warning, text: Text("scanner.instruction", bundle: .kit))
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay { cameraArea }
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            if let problem {
                VStack(alignment: .leading, spacing: 10) {
                    NoticeCard(symbol: "xmark.octagon.fill", tone: .warning,
                               text: Text(Self.explanation(problem), bundle: .kit))
                    Button(action: onDismissProblem) { Text("scanner.scanAgain", bundle: .kit) }
                        .buttonStyle(ActionButtonStyle(kind: .secondary))
                }
            }
            Button(action: onCancel) { Text("common.cancel", bundle: .kit) }
                .buttonStyle(ActionButtonStyle(kind: .secondary))
        }
    }

    @ViewBuilder private var cameraArea: some View {
        if camera == .authorized, !isSending {
            preview
        } else {
            ZStack {
                Color.black.opacity(0.85)
                VStack(spacing: 12) {
                    Image(systemName: isSending ? "hourglass" : "camera.fill")
                        .font(.system(size: 40))
                    Text(cameraMessage, bundle: .kit)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    if camera == .denied, !isSending {
                        Button {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        } label: {
                            Text("scanner.openSettings", bundle: .kit).font(.callout.bold())
                        }
                    }
                }
                .foregroundStyle(.white)
                .padding(24)
            }
        }
    }

    private var cameraMessage: LocalizedStringKey {
        if isSending { return "scanner.sending" }
        switch camera {
        case .authorized, .notDetermined: return "scanner.camera.notDetermined"
        case .denied: return "scanner.camera.denied"
        case .restricted: return "scanner.camera.restricted"
        case .unavailable: return "scanner.camera.unavailable"
        }
    }

    static func explanation(_ problem: ScanProblem) -> LocalizedStringKey {
        switch problem {
        case .notAPairingCode: return "scanner.problem.notAPairingCode"
        case .invalid: return "scanner.problem.invalid"
        case .expired: return "scanner.problem.expired"
        case .keyConflict: return "scanner.problem.keyConflict"
        case .deviceLimitReached: return "scanner.problem.deviceLimitReached"
        case .failed: return "scanner.problem.failed"
        }
    }
}

/// The pairing code to enter on the Mac. Before the challenge and the
/// reveal it says there is no code yet; in both states it says the code
/// appears only here and is never sent in a notification or a message.
struct PairingCodeContent: View {
    let display: PairingCodeDisplay?
    let isConfirming: Bool
    let problem: ConfirmProblem?
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ScreenContent(title: "pairing.title") {
            if let display {
                VStack(alignment: .leading, spacing: 12) {
                    // The code is display text only: no identifier, never logged.
                    Text(verbatim: display.digits)
                        .font(.system(size: 60, weight: .semibold, design: .rounded).monospacedDigit())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color(uiColor: .secondarySystemGroupedBackground)))
                    Text("pairing.code.instruction \(display.macName)", bundle: .kit)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "hourglass")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("pairing.noCode.title", bundle: .kit)
                        .font(.title2.bold())
                    Text("pairing.noCode.detail", bundle: .kit)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground)))
            }
            NoticeCard(symbol: "lock.fill", text: Text("pairing.code.onlyHere", bundle: .kit))
            if let display {
                if display.confirmed {
                    NoticeCard(symbol: "checkmark.circle.fill", tone: .success, text: Text("pairing.confirmed", bundle: .kit))
                } else {
                    if let problem {
                        NoticeCard(symbol: "exclamationmark.triangle.fill", tone: .warning,
                                   text: Text(Self.explanation(problem), bundle: .kit))
                    }
                    Button(action: onConfirm) { Text("pairing.confirm", bundle: .kit) }
                        .buttonStyle(ActionButtonStyle())
                        .disabled(isConfirming)
                    Text("pairing.confirm.footnote", bundle: .kit)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button(action: onCancel) { Text("pairing.cancel", bundle: .kit) }
                .buttonStyle(ActionButtonStyle(kind: .destructive))
        }
    }

    static func explanation(_ problem: ConfirmProblem) -> LocalizedStringKey {
        switch problem {
        case .cancelled: return "pairing.confirm.cancelled"
        case .failed: return "pairing.confirm.failed"
        case .unavailable: return "pairing.confirm.unavailable"
        }
    }
}

struct PairingResultContent: View {
    enum Outcome: Hashable {
        case paired(macName: String)
        case failed(PairingFailure)
    }

    let outcome: Outcome
    let onDone: () -> Void

    var body: some View {
        ScreenContent(title: title) {
            switch outcome {
            case .paired(let name):
                NoticeCard(symbol: "checkmark.seal.fill", tone: .success, text: Text("pairing.paired.detail \(name)", bundle: .kit))
            case .failed(let failure):
                NoticeCard(symbol: "xmark.octagon.fill", tone: .warning, text: Text(Self.explanation(failure), bundle: .kit))
            }
            Button(action: onDone) { Text("common.done", bundle: .kit) }
                .buttonStyle(ActionButtonStyle())
        }
    }

    private var title: LocalizedStringKey {
        if case .paired = outcome { return "pairing.paired.title" }
        return "pairing.failed.title"
    }

    static func explanation(_ failure: PairingFailure) -> LocalizedStringKey {
        switch failure {
        case .noChallenge: return "pairing.failed.noChallenge"
        case .cancelledByMac: return "pairing.failed.cancelledByMac"
        case .expired: return "pairing.failed.expired"
        case .conflictingChallenge: return "pairing.failed.conflictingChallenge"
        case .deviceLimitReached: return "pairing.failed.deviceLimitReached"
        case .keyConflict: return "pairing.failed.keyConflict"
        case .ended: return "pairing.failed.ended"
        }
    }
}
