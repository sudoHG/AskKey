import AppKit
import AskKeyDevices
import CoreImage.CIFilterBuiltins

/// What Settings → Devices keeps between redraws: the code the person is
/// typing, an inline rename and the open confirmations. Pairing, the list
/// and every rule about them belong to the coordinator; this model only
/// forwards the person's actions. It never holds or derives the Mac's
/// pairing code, and logs nothing.
@Observable
@MainActor
final class DevicesSettingsModel {
    let coordinator: DeviceCoordinator
    /// What the person typed into the code field. It is cleared once the
    /// code is accepted, so the field never shows a matching code.
    var codeEntry = ""
    var renameDraft = ""
    private(set) var renaming: DeviceID?
    private(set) var removalCandidate: DeviceID?
    private(set) var confirmingReset = false
    /// A code check or a confirmation is running; **Confirm** waits for it,
    /// so a double click can't count one entry twice.
    private(set) var isSubmitting = false
    /// **Pair Again** is replacing the session; the sheet stays open meanwhile.
    private(set) var isRestarting = false
    /// The iPhone whose **Approve agent requests** sheet is open.
    private(set) var approverSheetDevice: PairedDeviceRow?

    @ObservationIgnored private var qrCache: (text: String, image: NSImage)?

    init(coordinator: DeviceCoordinator) {
        self.coordinator = coordinator
    }

    /// Builds without CloudKit, and every Release build until stage 4, have
    /// no Devices section.
    var isSectionVisible: Bool { coordinator.availability != .notConfigured }

    var notice: DevicesPresentation.Notice {
        DevicesPresentation.sectionNotice(availability: availability, account: coordinator.account,
                                          deviceCount: coordinator.devices.count,
                                          storageFailureMessage: coordinator.storageFailureMessage)
    }

    var canPair: Bool {
        DevicesPresentation.canPair(availability: availability, account: coordinator.account,
                                    deviceCount: coordinator.devices.count, isPairing: coordinator.pairing != nil)
    }

    /// The coordinator's availability, except that a Mac without a Secure
    /// Enclave says so before the first attempt, not only after it.
    private var availability: DeviceServicesAvailability {
        let missingEnclave = coordinator.environment.backend?.isSecureEnclaveAvailable == false
        if coordinator.availability == .ready, !coordinator.hasIdentity, missingEnclave { return .secureEnclaveUnavailable }
        return coordinator.availability
    }

    var offersReset: Bool { DevicesPresentation.offersReset(coordinator.availability) }

    // MARK: Pairing sheet

    var isSheetPresented: Bool { coordinator.pairing != nil || isRestarting }

    var sheet: PairingSheetPresentation? {
        coordinator.pairing.map {
            PairingSheetPresentation(state: $0, feedback: coordinator.pairingFeedback,
                                     isAuthenticating: coordinator.isAuthenticatingPairing)
        }
    }

    /// Whether **Confirm** does something now: check a typed entry, or ask
    /// for system authentication again for an accepted code.
    var canConfirm: Bool {
        guard !isSubmitting else { return false }
        switch coordinator.pairing {
        case .enteringCode: return !codeEntry.isEmpty
        case .codeAccepted: return !coordinator.isAuthenticatingPairing
        default: return false
        }
    }

    /// The section appeared. The model outlives each visit to Settings, so
    /// a rename or confirmation left open on an earlier visit is closed.
    func sectionOpened() async {
        cancelRename()
        removalCandidate = nil
        confirmingReset = false
        if approverSheetDevice != nil { closeApproverSheet() }
        await coordinator.devicesOpened()
    }

    func pairDevice() async {
        guard canPair else { return }
        codeEntry = ""
        await coordinator.startPairing()
    }

    /// **Confirm**: checks the typed code; a wrong or malformed entry asks
    /// for nothing. An accepted code asks for system authentication at once;
    /// after a cancelled or failed prompt, **Confirm** asks again without a
    /// new entry.
    func confirm() async {
        guard canConfirm else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        if case .enteringCode = coordinator.pairing {
            await coordinator.enterPairingCode(codeEntry)
            switch coordinator.pairing {
            case .enteringCode:
                if case .wrongCode = coordinator.pairingFeedback { codeEntry = "" }
                return
            case .codeAccepted:
                codeEntry = ""
            default:
                codeEntry = ""
                return
            }
        }
        guard case .codeAccepted = coordinator.pairing else { return }
        await coordinator.confirmPairing()
    }

    /// **Cancel**, **Done**, **Close** or closing the sheet. A session that has
    /// not added the device ends with nothing stored; an added one stays.
    func closeSheet() async {
        codeEntry = ""
        qrCache = nil
        await coordinator.cancelPairing()
    }

    /// **Pair Again** after a session ended or its QR code expired: a new
    /// session and a new QR code in the same sheet.
    func pairAgain() async {
        guard !isRestarting else { return }
        isRestarting = true
        defer { isRestarting = false }
        codeEntry = ""
        qrCache = nil
        if coordinator.pairing?.isActive == true { await coordinator.cancelPairing() }
        guard DevicesPresentation.canPair(availability: availability, account: coordinator.account,
                                          deviceCount: coordinator.devices.count, isPairing: false) else {
            await coordinator.cancelPairing()
            return
        }
        await coordinator.startPairing()
    }

    /// The QR code image, drawn once per session with Core Image.
    func qrImage(for text: String) -> NSImage? {
        if let qrCache, qrCache.text == text { return qrCache.image }
        guard let image = Self.makeQRImage(text) else { return nil }
        qrCache = (text, image)
        return image
    }

    static func makeQRImage(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        // The software renderer needs no GPU and the image is a few hundred points.
        let context = CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false])
        guard let image = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: image, size: scaled.extent.size)
    }

    // MARK: Rows

    var canSaveRename: Bool { !DeviceDisplayName.clean(renameDraft).isEmpty }

    func beginRename(_ row: PairedDeviceRow) {
        removalCandidate = nil
        renaming = row.id
        renameDraft = row.displayName
    }

    func cancelRename() {
        renaming = nil
        renameDraft = ""
    }

    func saveRename() async {
        guard canSaveRename, let id = renaming, let row = coordinator.devices.first(where: { $0.id == id }) else { return }
        let renamed = await coordinator.renameDevice(row, to: renameDraft)
        if renamed || coordinator.lastIssue == .deviceNotFound { cancelRename() }
    }

    /// A delivery check needs the device services and the account the
    /// devices were paired in.
    var canTestDelivery: Bool {
        coordinator.availability == .ready && coordinator.account == .available
    }

    func testDelivery(_ row: PairedDeviceRow) async {
        guard canTestDelivery else { return }
        await coordinator.sendDeliveryCheck(to: row.id)
    }

    /// **Remove** asks first; only the confirmation removes the device.
    func requestRemoval(_ row: PairedDeviceRow) {
        cancelRename()
        removalCandidate = row.id
    }

    func cancelRemoval() {
        removalCandidate = nil
    }

    func confirmRemoval() async {
        guard let id = removalCandidate else { return }
        removalCandidate = nil
        await coordinator.removeDevice(id)
        // After an account change, the new account becomes the list's once
        // the list is empty, which only an account check notices.
        if coordinator.account == .accountChanged, coordinator.devices.isEmpty {
            await coordinator.devicesOpened()
        }
    }

    // MARK: Approver

    var isApproverSheetPresented: Bool { approverSheetDevice != nil }

    var approverSheet: ApproverSheetPresentation? {
        approverSheetDevice.map { ApproverSheetPresentation(device: $0, state: coordinator.approverConfirmation) }
    }

    /// Turning approval on needs the device services and the account the
    /// devices were paired in, which carries the iPhone's confirmation.
    var canTurnApproverOn: Bool {
        coordinator.availability == .ready && coordinator.account == .available
    }

    /// Turning it off only writes this Mac's list, so it also works while
    /// iCloud can't be reached.
    var canTurnApproverOff: Bool { coordinator.availability == .ready }

    func canChangeApprover(_ row: PairedDeviceRow) -> Bool {
        row.isApprover ? canTurnApproverOff : canTurnApproverOn
    }

    /// The switch. Turning it on opens the sheet on its first step, which
    /// only explains what will leave the Mac; turning it off takes effect at
    /// once and asks for no authentication. Mac rows have no switch.
    func setApprover(_ row: PairedDeviceRow, enabled: Bool) async {
        guard row.platform == .iOS, enabled != row.isApprover, canChangeApprover(row) else { return }
        guard enabled else {
            await coordinator.disableApprover(row)
            return
        }
        guard approverSheetDevice == nil else { return }
        cancelRename()
        removalCandidate = nil
        // An attempt that ended earlier leaves its state; this one starts fresh.
        coordinator.cancelApproverConfirmation()
        approverSheetDevice = row
    }

    /// **Continue**: system authentication, then the code.
    func continueApprover() async {
        guard let row = approverSheetDevice, coordinator.approverConfirmation == nil else { return }
        await coordinator.startApproverConfirmation(for: row.id)
    }

    /// **Start Again** after an attempt ended: system authentication again,
    /// then a new code.
    func startApproverAgain() async {
        guard let row = approverSheetDevice, case .ended? = coordinator.approverConfirmation else { return }
        coordinator.cancelApproverConfirmation()
        await coordinator.startApproverConfirmation(for: row.id)
    }

    /// **Cancel**, **Done**, **Close** or closing the sheet: the code and
    /// the authorization are discarded.
    func closeApproverSheet() {
        approverSheetDevice = nil
        coordinator.cancelApproverConfirmation()
    }

    /// The coordinator dropped an open attempt itself, for example when
    /// management locked; the sheet closes with it.
    func approverStateChanged(from old: ApproverConfirmationState?, to new: ApproverConfirmationState?) {
        if old?.isActive == true, new == nil, approverSheetDevice != nil { closeApproverSheet() }
    }

    // MARK: Reset

    /// **Reset Device Identity…** asks first; only the confirmation deletes
    /// the keys and the list.
    func requestReset() {
        guard offersReset else { return }
        confirmingReset = true
    }

    func cancelReset() {
        confirmingReset = false
    }

    func confirmReset() async {
        guard confirmingReset else { return }
        confirmingReset = false
        await coordinator.resetIdentity()
    }
}
