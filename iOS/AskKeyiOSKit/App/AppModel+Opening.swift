import AskKeyDevices
import Foundation

/// A tapped notification's request (#337). The sheet opens at once: with
/// the card when the app already holds the request, otherwise with a
/// loading state while the app fetches the one record the notification
/// named, before anything else it fetches. Only the record name comes from
/// the notification; the record goes through the same messenger and
/// handler as every other, so only a request the app verified, from a Mac
/// with the approval flag, becomes a card.
extension AppModel {
    /// Opens the request's sheet and, without its card, starts looking for it.
    func open(_ recordName: String) {
        openedRequest = OpenedRequest(id: recordName)
        if requests.contains(where: { $0.id == recordName }) {
            opening = nil
        } else {
            opening = OpeningRequest(id: recordName, since: environment.clock.now(), step: .fetchDue)
        }
    }

    /// Fetches the tapped record by name, once, as soon as the iCloud
    /// account is known and CloudKit's retry-after allows: before the inbox
    /// preparation and the zone poll of a pass, and alongside a pass that is
    /// already running, whose messenger handles a record both find once.
    /// Waits for the fetch when it starts it; returns at once otherwise.
    func fetchOpenedRecord(_ services: DeviceServices) async {
        guard openingWork == nil, var opening, opening.step == .fetchDue, stage == .ready, self.services === services,
              accountChecked, accountNotice == nil else { return }
        if let notBefore = namedFetchNotBefore, environment.clock.now() < notBefore { return }
        let name = opening.id
        guard approvals.index(of: name) == nil else {
            // Already stored: its card comes from the stored copy, which
            // launch opens again; a stored request without a card is settled
            // by the next pass.
            self.opening?.step = .waitingForPoll(after: inboxPasses)
            return
        }
        opening.step = .fetching
        self.opening = opening
        namedFetched.insert(name)
        let work = Task { [weak self] in
            guard let self else { return }
            await self.runOpeningFetch(name, services: services)
            self.openingWork = nil
        }
        openingWork = work
        await work.value
    }

    private func runOpeningFetch(_ name: String, services: DeviceServices) async {
        let before = try? await services.registry.list()
        var answer: InboxMessageOutcome?
        var found = true
        var kind: Int64?
        do {
            let report = try await services.messenger.fetchNamedMessages([name])
            guard self.services === services else { return }
            if let wait = report.retryAfter { postponeNamedFetches(by: wait) }
            answer = report.outcomes[name]
            found = !report.notYet.contains(name)
            let kinds = services.transport.takeKinds(for: report.outcomes.keys)
            kind = kinds[name]
            recordDeliveries(report.outcomes, kinds: kinds)
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
        switch answer {
        case .processed? where kind == Int64(MessageKind.deliveryCheck.rawValue):
            // Not a request: a delivery check, answered and recorded.
            openedRequest = openedRequest?.id == name ? nil : openedRequest
            self.opening = nil
        case .processed?, .refused?:
            self.opening?.step = .unavailable
        case nil where !found:
            self.opening?.step = .unavailable
        default:
            // Not fetched, or its handling failed for now: the next pass's
            // zone poll may still find it.
            self.opening?.step = .waitingForPoll(after: inboxPasses)
        }
    }

    /// At the end of an inbox pass: a tapped record still without a card
    /// whose own fetch gave no final answer before this pass started, or
    /// that cannot be fetched because iCloud is unavailable, is unavailable.
    /// A card that arrives later still replaces that state.
    func settleOpening(afterPass pass: Int) {
        guard let opening, !requests.contains(where: { $0.id == opening.id }) else { return }
        switch opening.step {
        case .waitingForPoll(let after) where after < pass:
            self.opening?.step = .unavailable
        case .fetchDue where accountNotice != nil:
            self.opening?.step = .unavailable
        default:
            break
        }
    }

    /// While the tapped request's sheet shows the loading state.
    func isLoadingOpenedRequest(at now: Date) -> Bool {
        guard let opening, openedRequest?.id == opening.id else { return false }
        return opening.phase(at: now) == .loading
    }

    /// Waits at least `seconds` before the next fetch by name; a longer wait
    /// already asked for stays.
    func postponeNamedFetches(by seconds: TimeInterval) {
        let requested = environment.clock.now().addingTimeInterval(seconds)
        namedFetchNotBefore = max(namedFetchNotBefore ?? requested, requested)
    }
}
