import AskKeyDevices
import Foundation

/// A tapped notification's request (#337). The sheet opens at once: with
/// the card when the app already holds the request, otherwise with a
/// loading state while the app fetches the one record the notification
/// named, before anything else it fetches. Only the record name comes from
/// the notification; the record goes through the same messenger and
/// handler as every other, so only a request the app verified, from a Mac
/// with the approval flag, becomes a card. Such a card cannot be decided,
/// and its receipt waits, until a zone poll that started after the fetch
/// handled any closed message already waiting for it.
extension AppModel {
    /// Opens the request's sheet and, without its card, starts looking for it.
    func open(_ recordName: String) {
        openedRequest = OpenedRequest(id: recordName)
        if requests.contains(where: { $0.id == recordName }) {
            opening = nil
        } else {
            opening = OpeningRequest(id: recordName, since: environment.clock.now())
        }
    }

    /// What the tapped request's sheet shows while it has no card; nil when
    /// the sheet shows another request or none.
    public func openingPhase(at now: Date) -> OpeningPhase? {
        guard let opening, openedRequest?.id == opening.id else { return nil }
        // Without iCloud nothing can be fetched; the record is still fetched
        // first once the account is back.
        return accountNotice == nil ? opening.phase(at: now) : .unavailable
    }

    func isLoadingOpenedRequest(at now: Date) -> Bool {
        openingPhase(at: now) == .loading
    }

    /// Fetches the tapped record by name as soon as the iCloud account is
    /// known and CloudKit's retry-after allows: before the inbox
    /// preparation and the zone poll of a pass, and alongside a pass that is
    /// already running, whose messenger handles a record both find once.
    /// An answer that settles nothing (a failed fetch or handling, a
    /// retry-after) leaves it due for the next pass, until loading ends.
    /// Waits for the fetch when it starts it; returns at once otherwise.
    func fetchOpenedRecord(_ services: DeviceServices) async {
        let now = environment.clock.now()
        guard var opening, opening.step == .fetchDue, openingWork[opening.id] == nil, now >= opening.nextAttempt,
              !opening.hasExpired(at: now), stage == .ready, self.services === services, accountChecked,
              accountNotice == nil else { return }
        if let notBefore = namedFetchNotBefore, now < notBefore { return }
        let name = opening.id
        if let index = approvals.index(of: name) {
            // Already stored: launch opens its card again, or drops it and
            // closes the sheet; a dismissed one stays hidden.
            if approvals.requests[index].dismissed { self.opening?.step = .unavailable }
            return
        }
        opening.step = .fetching
        self.opening = opening
        namedFetched.insert(name)
        uncheckedRequests.insert(name)
        services.transport.watchKind(of: name)
        let work = Task { [weak self] in
            guard let self else { return }
            await self.runOpeningFetch(name, services: services)
            self.openingWork[name] = nil
        }
        openingWork[name] = work
        await work.value
    }

    private func runOpeningFetch(_ name: String, services: DeviceServices) async {
        let before = try? await services.registry.list()
        var answer: InboxMessageOutcome?
        var found = true
        defer { _ = services.transport.takeWatchedKind(of: name) }
        do {
            let report = try await services.messenger.fetchNamedMessages([name])
            guard self.services === services else { return }
            if let wait = report.retryAfter { postponeNamedFetches(by: wait) }
            answer = report.outcomes[name]
            found = !report.notYet.contains(name)
            if case .processed? = answer, let kind = services.transport.takeWatchedKind(of: name) {
                recordDeliveries(report.outcomes, kinds: [name: kind])
            } else {
                recordDeliveries(report.outcomes, kinds: [:])
            }
        } catch is DeviceIdentityError {
            guard self.services === services else { return }
            return identityBecameUnusable()
        } catch {
            if let transportError = error as? DeviceTransportError, case .rateLimited(let wait?) = transportError {
                postponeNamedFetches(by: wait)
            }
            AppLog.failure("Fetching the opened message", error)
        }
        guard self.services === services, stage == .ready else { return }
        await refreshList(previous: before)
        guard self.services === services, self.opening?.id == name, self.opening?.step == .fetching else { return }
        // A card, or a delivery check (`recordDeliveries` closes its
        // sheet), has already ended the opening.
        switch answer {
        case .processed?, .refused?:
            self.opening?.step = .unavailable
        case nil where !found:
            self.opening?.step = .unavailable
        default:
            // Not fetched, or its handling failed for now: try again with
            // the next pass, after CloudKit's retry-after if it asked.
            self.opening?.step = .fetchDue
            self.opening?.nextAttempt = environment.clock.now().addingTimeInterval(Self.activePollInterval)
        }
    }

    /// Waits at least `seconds` before the next fetch by name; a longer wait
    /// already asked for stays.
    func postponeNamedFetches(by seconds: TimeInterval) {
        let requested = environment.clock.now().addingTimeInterval(seconds)
        namedFetchNotBefore = max(namedFetchNotBefore ?? requested, requested)
    }
}
