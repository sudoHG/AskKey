import AppKit
import CoreGraphics
import SwiftUI
@preconcurrency import UserNotifications
import AskKeyBroker
import AskKeyVault

extension AppDelegate {
    func setupApprovalQueue() {
        Vault.shared.approvalRequests.configureAuthentication { purpose in
            let reason = purpose == .readApproval
                ? ManagementAuthenticationAction.approveRead.reasonKey
                : ManagementAuthenticationAction.approveWrite.reasonKey
            return ManagementAuthenticationRunner.shared.authenticateBlocking(
                presentation: ManagementAuthenticationPresentation.current(reason: reason)
            )
        }
        Vault.shared.approvalRequests.configureObservers(
            notify: { _ in },
            pendingCountChanged: { [weak self] count in
                Task { @MainActor [weak self] in
                    self?.pendingApprovalCount = count
                    self?.vault.pendingApprovalCount = count
                    if count == 0 { self?.resetLockedApprovalReminder() }
                    if count > 0 { self?.presentPendingApproval() }
                }
            }
        )
        approvalPresentationObserver = NotificationCenter.default.addObserver(
            forName: .presentNextAgentApproval, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                self?.presentPendingApproval(operationID: note.object as? String)
            }
        }
        screenUnlockObserver = DistributedNotificationCenter.default.addObserver(
            forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.resetLockedApprovalReminder()
                self?.presentPendingApproval()
            }
        }
    }

    private func presentPendingApproval(
        operationID: String? = nil,
        cancelledAuthenticationDecision: BrokerApprovalDecision? = nil
    ) {
        guard !presentingApproval else { return }
        let pending: BrokerPendingApproval
        switch AgentApprovalPrivacyPolicy.gatedRequest(
            screenState: Self.screenState(),
            load: {
                AgentApprovalRequestSelection.select(
                    Vault.shared.approvalRequests.pendingRequests(),
                    operationID: operationID
                )
            }
        ) {
        case .lockedReminder(let title, let body):
            postLockedApprovalReminder(title: title, body: body)
            return
        case .detailed(let loaded):
            guard let loaded else { return }
            pending = loaded
            resetLockedApprovalReminder()
        }
        presentingApproval = true

        let request = pending.request
        runFrozenApprovalPanel(
            request: request,
            expiresAt: pending.expiresAt,
            pending: pending,
            cancelledAuthenticationDecision: cancelledAuthenticationDecision
        ) { [weak self] decision in
        guard let self else { return }
        guard let decision else {
            self.presentingApproval = false
            return
        }
        let fileWrites = self.fileWriteCoordinator
        let applyDecision: @Sendable () -> Void = { [weak self, fileWrites] in
            var didFail = false
            var authenticationCancelled = false
            do {
                _ = try Vault.shared.approvalRequests.decide(
                    requestID: pending.requestID,
                    capability: pending.capability,
                    decision: decision
                )
                if decision != .deny,
                   let fileWrites,
                   let summary = try? fileWrites.summary(requestID: pending.requestID) {
                    try fileWrites.commit(
                        requestID: pending.requestID,
                        capability: pending.capability,
                        expectedDigest: summary.digest
                    )
                }
            } catch BrokerApprovalError.authenticationFailed {
                // The request stays pending and nothing was delivered or changed.
                authenticationCancelled = true
            } catch {
                didFail = true
            }
            let failed = didFail
            let cancelled = authenticationCancelled
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.presentingApproval = false
                if cancelled {
                    self.presentPendingApproval(
                        operationID: pending.request.operationID,
                        cancelledAuthenticationDecision: decision
                    )
                } else if failed {
                    self.vault.errorMessage = "Ask Key could not apply this decision. Open Pending requests to retry or reject it."
                }
                // The retried request may have expired meanwhile; never leave
                // other requests waiting without a prompt.
                if !self.presentingApproval, !Vault.shared.approvalRequests.pendingRequests().isEmpty {
                    self.presentPendingApproval()
                }
            }
        }
        if decision == .deny {
            applyDecision()
        } else {
            DispatchQueue.global(qos: .userInitiated).async(execute: applyDecision)
        }
        }
    }

    private func runFrozenApprovalPanel(
        request: BrokerApprovalOperationRequest,
        expiresAt: Date?,
        pending: BrokerPendingApproval? = nil,
        cancelledAuthenticationDecision: BrokerApprovalDecision? = nil,
        completion: @escaping @MainActor (BrokerApprovalDecision?) -> Void = { _ in }
    ) {
        var finished = false
        var privacyTimer: Timer?
        var resizeObserver: NSObjectProtocol?
        let contentSize = NSSize(width: FrozenAgentApprovalPrompt.width, height: 360)
        let panel = AgentApprovalPanelFactory.make(contentSize: contentSize)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        let finish: (BrokerApprovalDecision?) -> Void = { value in
            guard !finished else { return }
            finished = true
            privacyTimer?.invalidate()
            privacyTimer = nil
            resizeObserver.map(NotificationCenter.default.removeObserver)
            resizeObserver = nil
            panel.orderOut(nil)
            panel.contentViewController = nil
            let valid = Self.screenState() == .unlocked && expiresAt.map({ $0 > Date() }) != false
            completion(valid ? value : nil)
        }
        let hosting = NSHostingController(
            rootView: FrozenAgentApprovalPrompt(
                request: request,
                trustedCredentialName: pending?.trustedCredentialName,
                expiresAt: expiresAt,
                timedAllowanceEnabled: vault.timedAllowanceEnabled,
                timedAllowanceMinutes: vault.defaultTimedAllowanceMinutes,
                writeSummary: pending.flatMap {
                    try? Vault.shared.frozenAgentWriteSummary(
                        operationID: $0.request.operationID,
                        requestID: $0.requestID, capability: $0.capability
                    )
                },
                organizationSummary: pending.flatMap {
                    try? Vault.shared.frozenAgentOrganizationSummary(operationID: $0.request.operationID,
                        requestID: $0.requestID, capability: $0.capability)
                },
                revealMaterial: pending.map { frozenPending in
                    { [weak self] in
                        guard let self, Self.screenState() == .unlocked else {
                            throw BrokerApprovalError.requestNotFound
                        }
                        let fileWrites = self.fileWriteCoordinator
                        let material = try await Task.detached(priority: .userInitiated) {
                            if let fileWrites, (try? fileWrites.summary(requestID: frozenPending.requestID)) != nil {
                                let file = try fileWrites.reveal(requestID: frozenPending.requestID)
                                return FrozenApprovalMaterial(
                                    title: file.originalFilename + " · " + String(file.byteCount) + " B",
                                    content: String(data: file.bytes, encoding: .utf8) ?? file.bytes.base64EncodedString(),
                                    encoding: String(data: file.bytes, encoding: .utf8) == nil ? "Base64" : "UTF-8"
                                )
                            }
                            guard ManagementAuthenticationRunner.shared.authenticateBlocking(
                                presentation: .current(reason: ManagementAuthenticationAction.revealFrozenFile.reasonKey)
                            ) else { throw BrokerFileWriteError.authenticationFailed }
                            let material = try Vault.shared.revealFrozenCredentialWrite(
                                operationID: frozenPending.request.operationID,
                                requestID: frozenPending.requestID,
                                capability: frozenPending.capability,
                                using: .allow
                            )
                            func describe(_ inputs: [CredentialComponentInput]) -> String {
                                inputs.map { item in
                                    let value: String
                                    switch item.value {
                                    case .text(let text): value = text
                                    case .file(let filename, let bytes):
                                        value = filename + " (" + String(bytes.count) + " B)\n"
                                            + (String(data: bytes, encoding: .utf8) ?? "Base64: " + bytes.base64EncodedString())
                                    }
                                    return item.name + "\n" + value
                                }.joined(separator: "\n\n")
                            }
                            return FrozenApprovalMaterial(
                                title: material.credentialName,
                                content: FrozenWriteRevealCopy.content(
                                    before: describe(material.before),
                                    after: describe(material.after)
                                ),
                                encoding: "UTF-8 / Base64"
                            )
                        }.value
                        guard Self.screenState() == .unlocked else { throw BrokerApprovalError.requestNotFound }
                        return material
                    }
                },
                cancelledAuthenticationDecision: cancelledAuthenticationDecision,
                finish: finish
            )
        )
        // The panel follows the prompt's height, including the Details section.
        hosting.sizingOptions = [.preferredContentSize]
        panel.contentViewController = hosting
        panel.setContentSize(hosting.view.fittingSize)
        panel.center()
        // Expanding Details makes the card taller; keep its buttons on screen.
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: panel, queue: .main
        ) { [weak panel] _ in
            MainActor.assumeIsolated {
                if let panel { Self.keepInsideVisibleFrame(panel) }
            }
        }
        // Common modes keep the check running during menus, drags and modal pickers.
        privacyTimer = Timer(timeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated {
                let requestEnded = pending.map {
                    (try? Vault.shared.approvalRequests.status(requestID: $0.requestID, capability: $0.capability)) != .pending
                } ?? false
                if Self.screenState() != .unlocked || expiresAt.map({ $0 <= Date() }) == true || requestEnded {
                    finish(nil)
                    if Self.screenState() == .unlocked { self.presentPendingApproval() }
                }
            }
        }
        if let privacyTimer { RunLoop.main.add(privacyTimer, forMode: .common) }
        panel.level = .modalPanel
        panel.makeKeyAndOrderFront(nil)
    }

    /// Moves the panel just enough to fit the screen's visible frame, keeping
    /// its top visible when it is taller than the screen.
    static func keepInsideVisibleFrame(_ panel: NSPanel) {
        guard let visible = (panel.screen ?? NSScreen.main)?.visibleFrame else { return }
        var origin = panel.frame.origin
        origin.y = min(max(origin.y, visible.minY), visible.maxY - panel.frame.height)
        if origin != panel.frame.origin { panel.setFrameOrigin(origin) }
    }

    nonisolated private static func screenState() -> AgentApprovalScreenState {
        AgentApprovalScreenSession.current()
    }

    private func postLockedApprovalReminder(title: String, body: String) {
        NSApp.dockTile.badgeLabel = "!"
        guard !lockedApprovalReminderPosted, lockedApprovalReminderAttempt == nil else { return }
        let attempt = UUID()
        lockedApprovalReminderAttempt = attempt
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { [weak self] settings in
            guard settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional else {
                Task { @MainActor [weak self] in
                    guard self?.lockedApprovalReminderAttempt == attempt else { return }
                    self?.lockedApprovalReminderAttempt = nil
                    self?.lockedApprovalReminderPosted = LockedApprovalReminderDeliveryPolicy
                        .marksNotificationPosted(for: .authorizationUnavailable)
                    NSLog(
                        "AskKey: locked approval notification unavailable; using Dock badge fallback"
                    )
                }
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            let request = UNNotificationRequest(
                identifier: "askkey-locked-approval-reminder",
                content: content,
                trigger: nil
            )
            center.add(request) { [weak self] error in
                Task { @MainActor [weak self] in
                    guard self?.lockedApprovalReminderAttempt == attempt else { return }
                    self?.lockedApprovalReminderAttempt = nil
                    let result: LockedApprovalReminderDeliveryResult = error == nil
                        ? .delivered
                        : .deliveryFailed
                    self?.lockedApprovalReminderPosted = LockedApprovalReminderDeliveryPolicy
                        .marksNotificationPosted(for: result)
                    if let error {
                        NSLog(
                            "AskKey: locked approval reminder failed; using Dock badge fallback: \(error.localizedDescription)"
                        )
                    }
                }
            }
        }
    }

    private func resetLockedApprovalReminder() {
        lockedApprovalReminderAttempt = nil
        lockedApprovalReminderPosted = false
        NSApp.dockTile.badgeLabel = nil
    }
}
