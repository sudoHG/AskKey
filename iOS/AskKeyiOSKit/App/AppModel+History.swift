import AskKeyDevices
import Foundation

/// The history of requests this app verified (ADR 0014 → iPhone app →
/// History, amended by #345). The app captures an open entry when it first
/// verifies a request and completes it once, when the request ends; only a
/// late closed message corrects a timed-out or gone outcome. Writes are best
/// effort: a failed write is retried at the next save and never blocks or
/// delays a decision, and "Saved to History." shows only after a write
/// succeeded.
extension AppModel {
    var historyStorage: EncryptedHistory {
        EncryptedHistory(files: environment.historyFiles, keys: environment.historyKeys)
    }

    /// The file is bound to the iCloud account's user record name.
    private var historyAccount: String? { environment.localState.inboxPosition?.userRecordName }

    // MARK: Capturing and completing

    /// The app verified and stored a request: its open entry, which History
    /// does not show yet, with the names in full as the request carries them
    /// and this iPhone's name for the Mac. Older requests the request left
    /// gone are completed.
    func historyAccepted(_ request: ApprovalRequest, _ message: VerifiedApprovalMessage, countdownEnd: Date) {
        let now = environment.clock.now()
        let entry = HistoryEntry(recordName: message.messageID.text, macID: message.senderID.text,
                                 pairingID: message.pairingID.rawValue, requestDigest: message.digest,
                                 requesterName: request.requesterName, credentialName: request.credentialName,
                                 executableName: request.executableName, macName: macName(of: message),
                                 receivedAt: now, countdownEnd: countdownEnd, endedAt: nil, decisionCode: nil,
                                 decisionCeiling: 0, closed: nil, gone: false)
        changeHistory { state in
            if state.index(of: entry.id) == nil { state.entries.append(entry) }
        }
        recordHistory()
    }

    /// The decision this iPhone stored and sent for a request, kept on its
    /// open entry, so a late closed message can be checked against it even
    /// after the stored request expired. Written after the decision was
    /// sent, never before.
    func historyDecided(_ request: StoredRequest) {
        guard let decision = request.decision else { return }
        let id = HistoryEntry.identity(macID: request.macID, pairingID: request.pairingID,
                                       requestDigest: request.requestDigest)
        changeHistory { state in
            guard let index = state.index(of: id), state.entries[index].endedAt == nil else { return }
            state.entries[index].decisionCode = decision.code
            state.entries[index].decisionCeiling = decision.durationCeiling
        }
        saveHistory()
    }

    /// A request whose closed message arrived first: one completed entry at
    /// once with the marker's outcome, received and ended now. A marker
    /// without an outcome, or with outcome 1, which cannot be this iPhone's
    /// decision, gives none. The outcome is used once, so an entry cleared
    /// or pruned later never comes back.
    func historyArrivedAfterClose(_ request: ApprovalRequest, _ message: VerifiedApprovalMessage, marker: StoredMarker) {
        guard let closed = marker.closed, closed.closedOutcome != .applied, RequestOutcome(closed) != nil else { return }
        let now = environment.clock.now()
        let entry = HistoryEntry(recordName: message.messageID.text, macID: message.senderID.text,
                                 pairingID: message.pairingID.rawValue, requestDigest: message.digest,
                                 requesterName: request.requesterName, credentialName: request.credentialName,
                                 executableName: request.executableName, macName: macName(of: message),
                                 receivedAt: now, countdownEnd: now, endedAt: now, decisionCode: nil,
                                 decisionCeiling: 0, closed: closed, gone: false)
        changeHistory { state in
            if state.index(of: entry.id) == nil { state.entries.append(entry) }
        }
        var state = approvals
        if let index = state.markers.firstIndex(of: marker) {
            state.markers[index].closed = nil
            commitApprovals(state)
        }
        saveHistory()
    }

    /// A closed message whose request the store no longer holds: it
    /// corrects the timed-out or gone entry with its identity, keeping the
    /// ended time, instead of being kept as a marker. Outcome 1 counts only
    /// as this iPhone's own decision, with its code and within its ceiling.
    /// Nil when no entry has this identity.
    func historyClosedLate(_ closed: ApprovalClosed, mac: String, pairing: Data, digest: Data) -> ApprovalMessageHandling? {
        let id = HistoryEntry.identity(macID: mac, pairingID: pairing, requestDigest: digest)
        guard let entry = historyState.entries.first(where: { $0.id == id }) else { return nil }
        guard entry.closed == nil else { return .refused(.replayed) }
        if closed.outcome == .applied {
            guard let code = entry.decisionCode, code == closed.appliedCode?.rawValue,
                  closed.appliedDuration <= entry.decisionCeiling else { return .refused(.bindingMismatch) }
        }
        let now = environment.clock.now()
        changeHistory { state in
            guard let index = state.index(of: id) else { return }
            if state.entries[index].endedAt == nil { state.entries[index].endedAt = min(now, entry.countdownEnd) }
            state.entries[index].closed = StoredClosed(closed)
            state.entries[index].gone = false
        }
        saveHistory()
        return .processed
    }

    /// Before requests are dropped because their Mac no longer approves
    /// (removed, unpaired by its notice, paired again, or a stored request
    /// that no longer opens): the ended ones are completed first, the others
    /// lose their open entries. The Mac's completed entries stay.
    func historyWillDrop(_ requests: [StoredRequest]) {
        guard !requests.isEmpty else { return }
        reconcileHistory()
        let now = environment.clock.now()
        let unfinished = Set(requests.filter { !$0.isFinished(at: now) }.map {
            HistoryEntry.identity(macID: $0.macID, pairingID: $0.pairingID, requestDigest: $0.requestDigest)
        })
        changeHistory { state in
            state.entries.removeAll { !$0.isCompleted && unfinished.contains($0.id) }
        }
        saveHistory()
    }

    /// After the stored requests changed: completes what ended and writes.
    func recordHistory() {
        reconcileHistory()
        saveHistory()
    }

    /// At launch, when the app comes to the front and after every fetch:
    /// reads the history if it could not be read yet, completes what ended,
    /// prunes and writes what is pending.
    func refreshHistory() {
        _ = historyIsWritable()
        reconcileHistory()
        changeHistory { _ in }
        saveHistory()
    }

    /// Completes every open entry whose request ended: its closed message
    /// arrived, its countdown ended, a later launch time left it gone, or it
    /// is no longer stored, for example after its transport expiry passed
    /// while the app was not running. The ended time is now, or the
    /// countdown's stored end if that is earlier. A closed message stored
    /// for a request whose entry timed out or went corrects it. Nothing
    /// happens while the stored requests cannot be read.
    func reconcileHistory() {
        guard approvalsReadable else { return }
        let now = environment.clock.now()
        let stored = Dictionary(approvals.requests.map {
            (HistoryEntry.identity(macID: $0.macID, pairingID: $0.pairingID, requestDigest: $0.requestDigest), $0)
        }, uniquingKeysWith: { first, _ in first })
        changeHistory { state in
            for index in state.entries.indices {
                let entry = state.entries[index]
                let request = stored[entry.id]
                if entry.isCompleted {
                    guard entry.isUnconfirmed, let closed = request?.closed else { continue }
                    state.entries[index].closed = closed
                    state.entries[index].gone = false
                    continue
                }
                if let request, !request.isFinished(at: now) { continue }
                var completed = entry
                completed.endedAt = min(now, entry.countdownEnd)
                if let request {
                    completed.decisionCode = request.decision?.code
                    completed.decisionCeiling = request.decision?.durationCeiling ?? 0
                    completed.closed = request.closed
                    completed.gone = request.closed == nil && request.gone
                }
                if let mac = DeviceID(text: entry.macID), let device = knownList?.device(mac),
                   device.pairingID.rawValue == entry.pairingID {
                    completed.macName = device.displayName
                }
                state.entries[index] = completed
            }
        }
    }

    private func macName(of message: VerifiedApprovalMessage) -> String {
        knownList?.device(message.senderID)?.displayName ?? message.sender.displayName
    }

    // MARK: Storage

    /// Applies a change in memory and prunes; `saveHistory()` writes it.
    func changeHistory(_ change: (inout StoredHistory) -> Void) {
        var state = historyState
        change(&state)
        state.prune(now: environment.clock.now())
        guard state != historyState else { return }
        historyState = state
        historyNeedsSave = true
        publishHistory()
    }

    /// At launch: reads the history under the current account, completes
    /// what ended while the app was not running, prunes and writes. Entries
    /// captured while it could not be read are kept and added to it. A file
    /// bound to another account, or one the key cannot open, is deleted
    /// unread.
    func loadHistory() {
        refreshHistory()
    }

    /// Whether the history may be written: no deletion is pending, and the
    /// file was read, or found missing, under the current account. Retries
    /// a pending deletion first, then the read.
    private func historyIsWritable() -> Bool {
        if historyDeletionPending {
            do {
                try historyStorage.delete()
            } catch {
                AppLog.failure("Deleting the history", error)
                return false
            }
            historyDeletionPending = false
            historyErased = true
            historyReadable = true
        }
        if historyReadable { return true }
        guard let account = historyAccount, let stored = historyStorage.load(account: account) else { return false }
        var merged = stored
        for entry in historyState.entries {
            if let index = merged.index(of: entry.id) {
                merged.entries[index] = entry
            } else {
                merged.entries.append(entry)
            }
        }
        historyReadable = true
        historyErased = false
        historyState = merged
        historyNeedsSave = merged != stored
        publishHistory()
        return true
    }

    /// Writes the history when a change is pending. A failed write keeps
    /// the change in memory for the next save.
    func saveHistory() {
        guard historyNeedsSave, historyIsWritable(), let account = historyAccount else { return }
        var state = historyState
        state.prune(now: environment.clock.now())
        do {
            try historyStorage.save(state, account: account)
        } catch {
            AppLog.failure("Storing the history", error)
            return
        }
        historyErased = false
        historyNeedsSave = false
        if state != historyState {
            historyState = state
            publishHistory()
        }
        savedHistory = Set(state.entries.filter(\.isCompleted).map(\.id))
    }

    /// Keeps History's list current: completed entries, most recently
    /// ended first.
    func publishHistory() {
        let completed = historyState.entries.filter(\.isCompleted).sorted { lhs, rhs in
            (lhs.endedAt!, lhs.receivedAt, lhs.id) > (rhs.endedAt!, rhs.receivedAt, rhs.id)
        }
        if completed != history { history = completed }
        let saved = savedHistory.intersection(completed.map(\.id))
        if saved != savedHistory { savedHistory = saved }
    }

    // MARK: Clearing and deleting

    /// **Clear All History**: every completed entry goes, in memory and on
    /// disk, with its pending writes, and the key is replaced, without
    /// reading the file; requests in progress keep their open entries,
    /// written again under the new key. It asks for no Face ID or Touch ID.
    public func clearHistory() {
        historyState.entries.removeAll(where: \.isCompleted)
        historyNeedsSave = !historyState.entries.isEmpty
        historyDeletionPending = true
        publishHistory()
        _ = historyIsWritable()
        saveHistory()
    }

    /// At an account change, sign-out or restriction, an identity reset and
    /// the welcome setup: every entry goes, with the in-memory entries and
    /// pending writes; the key first, then the file. A failed deletion is
    /// retried before anything is read or written, at every launch too.
    func deleteHistory() {
        if historyErased, historyState.entries.isEmpty, !historyDeletionPending { return }
        historyState = StoredHistory()
        historyNeedsSave = false
        historyDeletionPending = true
        savedHistory = []
        historyFilter = nil
        publishHistory()
        _ = historyIsWritable()
    }

    // MARK: Showing

    /// The completed entries of one Mac, by device ID.
    func historyCount(forMac macID: String) -> Int {
        history.filter { $0.macID == macID }.count
    }

    /// History for This Mac: the History tab, filtered to the Mac.
    public func showHistory(forMac macID: String) {
        historyFilter = macID
        selectedTab = .history
    }

    /// Whether the finished request's entry was written; the outcome page
    /// then says "Saved to History.".
    func isSavedToHistory(_ card: RequestCard) -> Bool {
        history.contains { $0.recordName == card.id && $0.macID == card.macID && savedHistory.contains($0.id) }
    }
}
