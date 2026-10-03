import AppKit
import AskKeyBroker
import AskKeyVault

extension AppDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if ManagementAuthenticationSubprocess.startIfRequested() { return }
        launchSource = AppLaunchSource(event: NSAppleEventManager.shared().currentAppleEvent)
        ensureManagementWindow()
        _ = managementDockPolicy.handle(
            .launch(isActive: launchSource == .active)
        )
        let presentation = AppLaunchPresentation.plan(for: launchSource)
        presentation.apply(
            setActivationPolicy: { [weak self] _ in
                self?.scheduleManagementDockPolicyApplication()
            },
            activateApplication: { NSApp.activate(ignoringOtherApps: true) },
            hideMainWindow: {
                self.hideManagementWindow()
                DispatchQueue.main.async { [weak self] in self?.hideManagementWindow() }
            }
        )
        if launchSource == .active {
            managementWindow?.makeKeyAndOrderFront(nil)
        }
        if let didStart = AppRuntimeState.configuration.didStart {
            setupWindowBehavior()
            setupStatusItemMenu()
            setupApprovalQueue()
            AppRuntimeState.configuration.prepareServices?()
            startBroker()
            didStart()
            return
        }
        recycleBinCleanupTimer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { _ in
            guard !Vault.shared.isLocked else { return }
            do {
                try Vault.shared.purgeExpiredRecycledCredentials()
            } catch {
                NSLog("AskKey: scheduled recycle-bin cleanup failed: \(error.localizedDescription)")
            }
        }
        setupApprovalQueue()
        Vault.shared.updateDefaultTimedAllowanceMinutes(vault.defaultTimedAllowanceMinutes)
        vault.retryBrokerStart = { [weak self] in self?.retryBrokerStart() }
        startBroker()
        if brokerServer != nil {
            do { try Vault.shared.purgeExpiredRecycledCredentials() }
            catch { vault.errorMessage = "Ask Key could not clean up expired recycled credentials." }
        }
        if AppRuntimeState.configuration.startClient?() == true { return }
        setupHotkey()
        setupWindowBehavior()
        setupStatusItemMenu()
        NotificationCenter.default.addObserver(
            forName: .hotkeyShortcutChanged, object: nil, queue: .main
        ) { [weak self] note in
            guard let id = note.object as? String else { return }
            Task { @MainActor [weak self] in
                self?.hotkeyManager.register(GlobalHotkeyManager.Shortcut.fromID(id))
            }
        }
    }

    // The public socket is the versioned, allow-listed Broker. Its providers expose
    // only Agent-safe projections; App-only Vault operations never enter the wire
    // protocol.
    private func startBroker() {
        guard brokerServer == nil else { return }
        let topology = OfficialInstallTopology.decide(
            bundleURL: Bundle.main.bundleURL,
            isDevelopmentBuild: VaultConfiguration.isDevelopmentBuild
        )
        guard OfficialInstallTopology.allowsOfficialRuntime(topology) else {
            vault.errorMessage = OfficialInstallCopy.message(for: topology)
            NSLog("AskKey: official runtime disabled because the installation topology is invalid")
            brokerServer?.stop()
            brokerServer = nil
            return
        }
        do {
            try Vault.shared.prepareAgentRuntime()
        } catch {
            if error is VaultBootstrapError {
                vault.errorMessage = UserFacingCopy.message(for: error)
            } else {
                vault.errorMessage = "Ask Key could not prepare Agent access. Open the app to review the vault state."
            }
            NSLog("AskKey: broker disabled because the vault store is unavailable: \(error.localizedDescription)")
            brokerServer?.stop()
            brokerServer = nil
            return
        }
        vault.refreshAgentAccessPauseState()
        if AppRuntimeState.configuration.didStart == nil {
            CredentialExpiryReminderController.shared.onAuthorizationFailure = { [weak self] message in
                Task { @MainActor [weak self] in
                    self?.vault.errorMessage = message
                }
            }
            CredentialExpiryReminderController.shared.start()
        }
        let fileWrites: BrokerFileWriteCoordinator
        let socketURL: URL
        do {
            socketURL = try BrokerConfiguration.resolvedSocketURL()
            fileWrites = try BrokerFileWriteCoordinator(
                stagingDirectory: socketURL
                    .deletingLastPathComponent()
                    .appendingPathComponent("file-write-staging", isDirectory: true),
                approvals: Vault.shared.approvalRequests,
                authenticateReveal: { Self.authenticateFileReveal() },
                commitFrozenFile: { [weak self] file in
                    try Vault.shared.commitAgentFileWrite(file)
                    Task { @MainActor [weak self] in self?.vault.refreshCredentialSummary() }
                },
                submitFrozenApproval: { credentialID, expectedDigest, request in
                    do {
                        return try Vault.shared.submitFileWriteApprovalIfCurrent(
                            credentialID: credentialID,
                            expectedPreviousDigest: expectedDigest,
                            request: request
                        )
                    } catch VaultError.agentAccessPaused {
                        throw BrokerProviderError.agentAccessPaused
                    } catch VaultError.credentialUnavailable {
                        throw BrokerProviderError.requestRejected
                    }
                },
                normalizeCreateTarget: {
                    try Vault.shared.normalizeAgentCreateCredentialName($0)
                },
                resolvePreviousDigest: { credentialID in
                    do {
                        return try Vault.shared.brokerFileContentDigest(
                            credentialID: credentialID
                        )
                    } catch VaultError.agentAccessPaused {
                        throw BrokerProviderError.agentAccessPaused
                    } catch VaultError.credentialUnavailable {
                        throw BrokerProviderError.requestRejected
                    }
                },
                completedFileCommit: { requestID, capability, expectedDigest in
                    try Vault.shared.completedAgentFileWrite(requestID: requestID,
                        capability: capability, expectedDigest: expectedDigest)
                }
            )
            fileWriteCoordinator = fileWrites
        } catch {
            presentBrokerRuntimeFailure(error)
            return
        }
        let textRuntime = BrokerTextRuntime(resolveCredentials: { request, cancellation in
            do {
                return try Vault.shared.brokerTextCredentials(for: request, cancellation: cancellation)
            } catch VaultError.agentAccessPaused {
                throw BrokerProviderError.agentAccessPaused
            } catch VaultError.credentialUnavailable {
                throw BrokerProviderError.requestRejected
            }
        })
        let handler = BrokerRequestHandler(
            catalog: {
                do {
                    let catalog = try Vault.shared.brokerCredentialCatalog(cancellation: $0)
                    Vault.shared.recordCredentialAccess(.init(
                        timestamp: Date(), credentialID: nil, operation: .catalog,
                        result: .allowed, callerHint: nil, declaredPurpose: nil
                    ))
                    return catalog
                } catch VaultError.agentAccessPaused {
                    Vault.shared.recordCredentialAccess(.init(
                        timestamp: Date(), credentialID: nil, operation: .catalog,
                        result: .denied, callerHint: nil, declaredPurpose: nil
                    ))
                    throw BrokerProviderError.agentAccessPaused
                }
            },
            requestStatus: { requestID, capability in
                if let completed = try Vault.shared.committedAgentFileWriteStatus(
                    requestID: requestID, capability: capability) {
                    return completed
                }
                do {
                    return try Vault.shared.approvalRequests.status(
                        requestID: requestID,
                        capability: capability
                    )
                } catch BrokerApprovalError.requestNotFound {
                    return Vault.shared.brokerRequests.status(
                        requestID: requestID,
                        capability: capability
                    )
                }
            },
            cancelRequest: { requestID, capability in
                do {
                    return try Vault.shared.approvalRequests.cancel(
                        requestID: requestID,
                        capability: capability
                    )
                } catch BrokerApprovalError.requestNotFound {
                    return Vault.shared.brokerRequests.cancel(
                        requestID: requestID,
                        capability: capability
                    )
                }
            },
            textRun: { request, descriptors, cancellation in
                try textRuntime.run(
                    request,
                    standardInputFD: descriptors.standardInput,
                    standardOutputFD: descriptors.standardOutput,
                    standardErrorFD: descriptors.standardError,
                    controlFD: descriptors.control,
                    cancellation: cancellation
                )
            },
            fileWrite: { try fileWrites.handle($0) },
            submitTextWrite: { request, cancellation in
                try cancellation.check()
                return try mapAgentTextWriteProviderError {
                    try Vault.shared.requestAgentTextWrite(request, fileResolver: { reference in
                        try fileWrites.resolveComponent(reference, operationID: request.operationID)
                    })
                }
            },
            commitTextWrite: { [weak self] request, requestID, capability in
                let result = try mapAgentTextWriteProviderError {
                    try Vault.shared.commitAgentTextWrite(
                        request,
                        requestID: requestID,
                        capability: capability
                    )
                }
                Task { @MainActor [weak self] in self?.vault.refreshCredentialSummary() }
                return result
            },
            cancelTextWrite: { operationID, requestID, capability in
                try mapAgentTextWriteProviderError {
                    try Vault.shared.cancelAgentTextWrite(
                        operationID: operationID,
                        requestID: requestID,
                        capability: capability
                    )
                }
            }
        )
        let server = BrokerSocketServer(
            socketPath: BrokerConfiguration.socketURL.path,
            handler: handler
        )
        do {
            try server.start()
            brokerServer = server
            vault.clearBrokerRuntimeFailure()
            vault.refreshAgentAccessPauseState()
        } catch {
            presentBrokerRuntimeFailure(error)
        }
    }

    private func presentBrokerRuntimeFailure(_ error: Error) {
        vault.presentBrokerRuntimeFailure(error)
        vault.retryBrokerStart = { [weak self] in
            self?.retryBrokerStart()
        }
        NSLog("AskKey: broker runtime is unavailable")
    }

    private func retryBrokerStart() {
        var recovery = BrokerRuntimeRecovery(
            isRunning: { [weak self] in self?.brokerServer != nil },
            start: { [weak self] in
                guard let self else { return }
                self.startBroker()
                if self.brokerServer == nil, self.vault.brokerRecoveryAvailable {
                    throw BrokerFileWriteError.stagingFailed
                }
            }
        )
        _ = recovery.retry()
    }

    nonisolated private static func authenticateFileReveal() -> Bool {
        return ManagementAuthenticationRunner.shared.authenticateBlocking(
            presentation: ManagementAuthenticationPresentation.current(
                reason: "View the frozen file submitted for approval"
            )
        )
    }
}

private func mapAgentTextWriteProviderError<T>(_ body: () throws -> T) throws -> T {
    do {
        return try body()
    } catch BrokerApprovalError.capacityReached {
        throw BrokerProviderError.resourceExhausted
    } catch BrokerApprovalError.requestNotFound {
        throw BrokerProviderError.requestNotFound
    } catch BrokerApprovalError.invalidRequest,
            BrokerApprovalError.payloadMismatch,
            BrokerApprovalError.invalidDecision,
            BrokerApprovalError.alreadyConsumed {
        throw BrokerProviderError.invalidRequest
    } catch BrokerApprovalError.agentAccessPaused, VaultError.agentAccessPaused {
        throw BrokerProviderError.agentAccessPaused
    } catch VaultError.credentialUnavailable, VaultError.credentialNotFound {
        throw BrokerProviderError.requestNotFound
    } catch {
        throw error
    }
}
