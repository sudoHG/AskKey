import AppKit
import CoreGraphics
import SwiftUI
import Observation
@preconcurrency import UserNotifications
import AskKeyBroker
import AskKeyVault

extension AppDelegate {
    func setupApprovalQueue() {
        Vault.shared.approvalRequests.configureAuthentication { purpose in
            let reason = purpose == .readApproval
                ? ManagementAuthenticationAction.approveRead.reasonKey
                : ManagementAuthenticationAction.approveWrite.reasonKey
            let attempt = ApprovalAuthenticationAttempt.current
            let outcome = ManagementAuthenticationRunner.shared.outcomeBlocking(
                presentation: ManagementAuthenticationPresentation.current(reason: reason),
                cancellation: attempt?.cancellation ?? .init()
            )
            return attempt?.record(outcome) ?? (outcome == .authenticated)
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
                self?.presentPendingApproval(operationID: note.object as? String, userInitiated: true)
            }
        }
        screenUnlockObserver = DistributedNotificationCenter.default.addObserver(
            forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.resetLockedApprovalReminder()
                self?.approvalPresentation.refreshAfterResume()
            }
        }
        approvalWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.approvalPresentation.refreshAfterResume() }
        }
    }

    private func presentPendingApproval(
        operationID: String? = nil,
        cancelledAuthenticationDecision: BrokerApprovalDecision? = nil,
        authenticationOutcome: ManagementAuthenticationOutcome? = nil,
        userInitiated: Bool = false
    ) {
        approvalPresentation.presentPendingApproval(
            operationID: operationID,
            cancelledAuthenticationDecision: cancelledAuthenticationDecision,
            authenticationOutcome: authenticationOutcome,
            userInitiated: userInitiated
        )
    }

    func makeApprovalPresentationCoordinator() -> AgentApprovalPresentationCoordinator {
        AgentApprovalPresentationCoordinator(
            screenState: { Self.screenState() },
            presentationBlocked: { NSApp.modalWindow != nil },
            modalReminder: { [weak self] in
                self?.postLockedApprovalReminder(
                    title: appLocalized("Ask Key has pending requests"),
                    body: appLocalized("Open Ask Key to review pending requests.")
                )
            },
            loadPending: { Vault.shared.approvalRequests.pendingRequests() },
            refreshExpiration: { Vault.shared.approvalRequests.refreshExpiration() },
            lockedReminder: { [weak self] title, body in
                self?.postLockedApprovalReminder(title: title, body: body)
            },
            feedback: { [weak self] message in self?.vault.errorMessage = message },
            present: { [weak self] pending, cancelledDecision, outcome, completion in
                guard let self else { return AgentApprovalPanelActions(bringForward: {}, dismiss: {}) }
                self.resetLockedApprovalReminder()
                return self.runFrozenApprovalPanel(
                    request: pending.request,
                    expiresAt: pending.expiresAt,
                    pending: pending,
                    cancelledAuthenticationDecision: cancelledDecision,
                    authenticationOutcome: outcome,
                    completion: completion
                )
            },
            applyDecision: { [weak self] pending, decision in
                self?.applyApprovalDecision(pending: pending, decision: decision)
            }
        )
    }

    private func applyApprovalDecision(pending: BrokerPendingApproval, decision: BrokerApprovalDecision) {
        let fileWrites = self.fileWriteCoordinator
        let attempt = ApprovalAuthenticationAttempt(
            pending: pending, requests: Vault.shared.approvalRequests,
            screenUnlocked: { Self.screenState() == .unlocked }
        )
        let applyDecision: @Sendable () -> Void = { [weak self, fileWrites] in
            var didFail = false
            var authenticationOutcome: ManagementAuthenticationOutcome?
            do {
                _ = try ApprovalAuthenticationAttempt.$current.withValue(attempt) {
                    try Vault.shared.decideAgentApproval(
                        requestID: pending.requestID,
                        capability: pending.capability,
                        decision: decision
                    )
                }
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
                authenticationOutcome = attempt.outcome
            } catch {
                didFail = true
            }
            let failed = didFail
            let outcome = authenticationOutcome
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.approvalPresentation.decisionFinished()
                if let outcome {
                    self.presentPendingApproval(
                        operationID: pending.request.operationID,
                        cancelledAuthenticationDecision: outcome == .cancelled ? decision : nil,
                        authenticationOutcome: outcome
                    )
                } else if failed {
                    self.vault.errorMessage = "Ask Key could not apply this decision. Open Pending requests to retry or reject it."
                }
                // The retried request may have expired meanwhile; never leave
                // other requests waiting without a prompt.
                if !self.approvalPresentation.isPresenting, !Vault.shared.approvalRequests.pendingRequests().isEmpty {
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

    private func runFrozenApprovalPanel(
        request: BrokerApprovalOperationRequest,
        expiresAt: Date?,
        pending: BrokerPendingApproval? = nil,
        cancelledAuthenticationDecision: BrokerApprovalDecision? = nil,
        authenticationOutcome: ManagementAuthenticationOutcome? = nil,
        completion: @escaping @MainActor (BrokerApprovalDecision?) -> Void = { _ in }
    ) -> AgentApprovalPanelActions {
        var finished = false
        var privacyTimer: Timer?
        var dismissPanel: () -> Void = {}
        let cancellation = ManagementAuthenticationCancellation {
            Self.screenState() != .unlocked || expiresAt.map { $0 <= Date() } == true ||
                pending.map {
                    (try? Vault.shared.approvalRequests.status(requestID: $0.requestID, capability: $0.capability)) != .pending
                } == true
        }
        let finish: (BrokerApprovalDecision?) -> Void = { value in
            guard !finished else { return }
            finished = true
            cancellation.cancel()
            privacyTimer?.invalidate()
            privacyTimer = nil
            dismissPanel()
            let valid = Self.screenState() == .unlocked && expiresAt.map({ $0 > Date() }) != false
            completion(valid ? value : nil)
        }
        let panel = Self.makeFrozenApprovalPanel(
            FrozenAgentApprovalPrompt(
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
                                let attempt = ApprovalAuthenticationAttempt(requestEnded: { cancellation.isCancelled })
                                let file = try ApprovalAuthenticationAttempt.$current.withValue(attempt) {
                                    try fileWrites.reveal(requestID: frozenPending.requestID)
                                }
                                return FrozenApprovalMaterial(
                                    title: file.originalFilename + " · " + String(file.byteCount) + " B",
                                    content: String(data: file.bytes, encoding: .utf8) ?? file.bytes.base64EncodedString(),
                                    encoding: String(data: file.bytes, encoding: .utf8) == nil ? "Base64" : "UTF-8"
                                )
                            }
                            guard ManagementAuthenticationRunner.shared.outcomeBlocking(
                                presentation: .current(reason: ManagementAuthenticationAction.revealFrozenFile.reasonKey),
                                cancellation: cancellation
                            ) == .authenticated else { throw BrokerFileWriteError.authenticationFailed }
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
                authenticationOutcome: authenticationOutcome,
                finish: finish
            )
        )
        dismissPanel = { [weak panel] in
            panel?.orderOut(nil)
            panel?.contentViewController = nil
        }
        // Common modes keep the check running during menus, drags and modal pickers.
        privacyTimer = Timer(timeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated {
                let requestEnded = pending.map {
                    (try? Vault.shared.approvalRequests.status(requestID: $0.requestID, capability: $0.capability)) != .pending
                } ?? false
                if Self.screenState() != .unlocked || expiresAt.map({ $0 <= Date() }) == true || requestEnded {
                    finish(nil)
                }
            }
        }
        if let privacyTimer { RunLoop.main.add(privacyTimer, forMode: .common) }
        panel.level = .modalPanel
        AgentApprovalPanelPlacement.bringForward(panel)
        return AgentApprovalPanelActions(
            bringForward: { AgentApprovalPanelPlacement.bringForward(panel) },
            dismiss: { finish(nil) }
        )
    }

    /// Shared by live presentation and hidden layout tests. No window is ordered in here.
    static func makeFrozenApprovalPanel(
        _ prompt: FrozenAgentApprovalPrompt,
        visibleFrame: @escaping @MainActor (NSPanel) -> NSRect? = { ($0.screen ?? NSScreen.main)?.visibleFrame }
    ) -> NSPanel {
        let panel = AgentApprovalPanelFactory.make(
            contentSize: NSSize(width: FrozenAgentApprovalPrompt.width, height: 360))
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        if let visible = AgentApprovalPanelPlacement.targetVisibleFrame() {
            panel.setFrameOrigin(AgentApprovalPanelPlacement.centeredOrigin(size: panel.frame.size, visibleFrame: visible))
        }
        let layout = AgentApprovalPanelLayout(panel: panel, visibleFrame: visibleFrame)
        let hosting = NSHostingController(rootView: AgentApprovalPanelContent(prompt: prompt, layout: layout))
        hosting.sizingOptions = [.preferredContentSize]
        panel.contentViewController = hosting
        layout.start()
        return panel
    }

    nonisolated private static func screenState() -> AgentApprovalScreenState {
        AgentApprovalScreenSession.current()
    }

    private func postLockedApprovalReminder(title: String, body: String) {
        NSApp.dockTile.badgeLabel = "!"
        guard !lockedApprovalReminderPosted, lockedApprovalReminderAttempt == nil else { return }
        let attempt = UUID()
        lockedApprovalReminderAttempt = attempt
        postApprovalNotification(identifier: "askkey-locked-approval-reminder", title: title, body: body) { [weak self] result in
            guard let self, self.lockedApprovalReminderAttempt == attempt else { return }
            self.lockedApprovalReminderAttempt = nil
            self.lockedApprovalReminderPosted = LockedApprovalReminderDeliveryPolicy.marksNotificationPosted(for: result)
            self.setLockedApprovalReminderFallbackVisible(!self.lockedApprovalReminderPosted)
        }
    }

    func presentAgentWriteNameUnavailable() {
        let message = "This credential name is already in use. The credential was not saved."
        presentAgentWriteFailure(message)
    }

    func presentAgentWriteMaterialTooLarge() {
        let message = "The updated credential exceeds the 5 MiB size limit. The credential was not saved."
        presentAgentWriteFailure(message)
    }

    private func presentAgentWriteFailure(_ message: String) {
        vault.errorMessage = message
        let attempt = UUID()
        _ = managementDockPolicy.handle(.agentWriteFailureStarted(attempt))
        observeAgentWriteFailureAcknowledgement(attempt)
        postApprovalNotification(identifier: "askkey-agent-write-failure", title: vault.brandName,
            body: displayedUserMessage(message)) { [weak self] result in
                guard let self else { return }
                _ = self.managementDockPolicy.handle(.agentWriteFailureDeliveryFinished(attempt, result))
                self.scheduleManagementDockPolicyApplication()
            }
    }

    private func observeAgentWriteFailureAcknowledgement(_ attempt: UUID) {
        guard managementDockPolicy.agentWriteFailureReminder == attempt else { return }
        withObservationTracking {
            _ = vault.errorMessage
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.managementDockPolicy.agentWriteFailureReminder == attempt else { return }
                if self.vault.errorMessage == nil {
                    self.resetAgentWriteFailureReminder()
                } else {
                    self.observeAgentWriteFailureAcknowledgement(attempt)
                }
            }
        }
    }

    func resetAgentWriteFailureReminder() {
        _ = managementDockPolicy.handle(.agentWriteFailureAcknowledged)
        if !lockedApprovalReminderPosted, lockedApprovalReminderAttempt == nil,
           !managementDockPolicy.lockedApprovalReminderFallbackVisible {
            NSApp.dockTile.badgeLabel = nil
        }
        scheduleManagementDockPolicyApplication()
    }

    private func postApprovalNotification(
        identifier: String, title: String, body: String,
        completion: @escaping @MainActor (LockedApprovalReminderDeliveryResult) -> Void
    ) {
        NSApp.dockTile.badgeLabel = "!"
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional else {
                Task { @MainActor in
                    completion(.authorizationUnavailable)
                    NSLog(
                        "AskKey: approval notification unavailable; using Dock badge fallback"
                    )
                }
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.userInfo = NotificationRoute.pendingRequests.userInfo
            let request = UNNotificationRequest(
                identifier: identifier,
                content: content,
                trigger: nil
            )
            center.add(request) { error in
                let delivered = error == nil
                Task { @MainActor in
                    completion(delivered ? .delivered : .deliveryFailed)
                    if !delivered {
                        NSLog(
                            "AskKey: approval notification failed; using Dock badge fallback"
                        )
                    }
                }
            }
        }
    }

    private func resetLockedApprovalReminder() {
        lockedApprovalReminderAttempt = nil
        lockedApprovalReminderPosted = false
        setLockedApprovalReminderFallbackVisible(false)
        if managementDockPolicy.agentWriteFailureReminder == nil { NSApp.dockTile.badgeLabel = nil }
    }
}
