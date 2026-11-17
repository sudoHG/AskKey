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
///
/// Before the card, the page says how opening stands (#348): loading, then
/// slow, then failed with Try Again; ended, saying how when the app knows;
/// or unverified. None of these shows anything from the notification.
extension AppModel {
    /// Opens the request's sheet and, without its card, starts looking for it.
    func open(_ recordName: String) {
        guard MessageID(text: recordName) != nil else { return openUnverified() }
        openedRequest = OpenedRequest(id: recordName)
        if requests.contains(where: { $0.id == recordName }) {
            opening = nil
        } else {
            opening = OpeningRequest(id: recordName, since: environment.clock.now())
        }
    }

    /// A tapped notification that names a record but no request this app
    /// can look for: its extension's record name is not a message ID. Its
    /// page says the notification could not be verified (#348).
    func openUnreadable(_ userInfo: [AnyHashable: Any]) {
        if userInfo[PushHintReader.extensionRecordNameKey] != nil { openUnverified() }
    }

    /// Opens the unverified page under a fixed ID, so nothing of the
    /// notification's name is kept or shown, and fetches nothing.
    private func openUnverified() {
        let id = OpeningRequest.unverifiedID
        openedRequest = OpenedRequest(id: id)
        opening = OpeningRequest(id: id, since: environment.clock.now(), step: .unverified)
    }

    /// What the tapped request's sheet shows while it has no card; nil when
    /// the sheet shows another request or none.
    public func openingPhase(at now: Date) -> OpeningPhase? {
        guard let opening, openedRequest?.id == opening.id else { return nil }
        let phase = opening.phase(at: now)
        switch phase {
        case .loading, .slow:
            // Without iCloud nothing can be fetched; the record is still
            // fetched first once the account is back.
            return accountNotice == nil ? phase : .failed
        case .failed, .ended, .unverified:
            return phase
        }
    }

    /// False in the first 0.3 seconds after the tap or Try Again: the page
    /// shows only its frame, so a fast load never flashes the placeholder.
    public func openingShowsPlaceholder(at now: Date) -> Bool {
        opening?.showsPlaceholder(at: now) ?? true
    }

    /// The tapped record is still fetched by name: at most a minute after
    /// the tap or Try Again, whatever the page says meanwhile.
    func isLoadingOpenedRequest(at now: Date) -> Bool {
        guard let opening, openedRequest?.id == opening.id, accountNotice == nil else { return false }
        return opening.isFetching(at: now)
    }

    /// Try Again on the failed page: the page loads again with its timers
    /// and its minute of fetching by name started over, and a pass follows,
    /// as after the tap. The record is fetched by name at once unless
    /// CloudKit asked to wait or its own fetch is still running; that
    /// fetch's answer then counts, and the next one follows with a later
    /// pass. Two fetches of one record never run at once.
    public func retryOpening() async {
        let now = environment.clock.now()
        guard var opening, openingPhase(at: now) == .failed else { return }
        opening.since = now
        opening.nextAttempt = now
        opening.fetchFailed = false
        opening.failed = false
        self.opening = opening
        guard let services else { return }
        await fetchOpenedRecord(services)
        await processInbox()
    }

    /// View History on the ended page: closes the page and shows the
    /// History tab.
    public func showHistory() {
        openedRequest = nil
        selectedTab = .history
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
            if approvals.requests[index].dismissed { self.opening?.step = .ended(endedRequest(name)) }
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
        // The fetch or the record's handling failed; asking to wait is not a failure.
        var failed = false
        defer { _ = services.transport.takeWatchedKind(of: name) }
        do {
            let report = try await services.messenger.fetchNamedMessages([name])
            guard self.services === services else { return }
            if let wait = report.retryAfter { postponeNamedFetches(by: wait) }
            answer = report.outcomes[name]
            found = !report.notYet.contains(name)
            // A record CloudKit asked to wait for is reported failed too.
            failed = answer == .failed && report.retryAfter == nil
            noteRefusals(report.outcomes)
            if case .processed? = answer, let kind = services.transport.takeWatchedKind(of: name) {
                recordDeliveries(report.outcomes, kinds: [name: kind])
            } else {
                recordDeliveries(report.outcomes, kinds: [:])
            }
        } catch is DeviceIdentityError {
            guard self.services === services else { return }
            return identityBecameUnusable()
        } catch {
            if let transportError = error as? DeviceTransportError, case .rateLimited(let wait) = transportError {
                if let wait { postponeNamedFetches(by: wait) }
            } else {
                failed = true
            }
            AppLog.failure("Fetching the opened message", error)
        }
        guard self.services === services, stage == .ready else { return }
        await refreshList(previous: before)
        guard self.services === services, self.opening?.id == name, self.opening?.step == .fetching else { return }
        // A card, or a delivery check (`recordDeliveries` closes its
        // sheet), has already ended the opening.
        switch answer {
        case .processed?:
            // Handled without a card: a closed message that arrived first
            // ended it, or the record was not a request.
            self.opening?.step = .ended(endedRequest(name))
        case .refused(let refusal)?:
            self.opening?.step = step(refusedFor: refusal, name)
        case nil where !found:
            // Gone: refused earlier in this process, or ended.
            self.opening?.step = unverifiedRecords.contains(name) ? .unverified : .ended(endedRequest(name))
        default:
            // Not fetched, or its handling failed for now: try again with
            // the next pass, after CloudKit's retry-after if it asked.
            self.opening?.step = .fetchDue
            self.opening?.nextAttempt = environment.clock.now().addingTimeInterval(Self.activePollInterval)
            if failed { self.opening?.fetchFailed = true }
        }
    }

    /// The end of a pass: what its zone poll and pushed fetches did with
    /// the tapped record settles the page as the record's own fetch would,
    /// a refused record unverified and one handled without a card ended.
    /// Otherwise, when the record's own fetch had failed in the same attempt
    /// before the zone poll started (`failedAttempt`) and the pass found no
    /// card, the page says the request could not be fetched; fetching goes
    /// on until loading ends.
    func settleOpening(after outcomes: [String: InboxMessageOutcome], failedAttempt: OpeningAttempt?) {
        noteRefusals(outcomes)
        guard var opening else { return }
        if case .refused(let refusal)? = outcomes[opening.id], Self.unverifies(refusal) {
            // The pass refused the record itself; its own fetch may have
            // found it already handled meanwhile and said it ended.
            guard opening.step != .unverified else { return }
            opening.step = .unverified
        } else {
            guard opening.step == .fetchDue || opening.step == .fetching else { return }
            switch outcomes[opening.id] {
            case .refused(let refusal)?:
                opening.step = step(refusedFor: refusal, opening.id)
            case .processed?:
                opening.step = .ended(endedRequest(opening.id))
            default:
                guard opening.fetchFailed, opening.attempt == failedAttempt else { return }
                opening.failed = true
            }
        }
        self.opening = opening
    }

    /// What a refusal of the tapped record says. Expired, or already handled
    /// by another fetch (`.replayed`): it ended, as far as the app knows,
    /// with only an outcome the app already holds and nothing from the
    /// refused record; a request decided on the Mac before the tap is the
    /// usual case. Any other refusal: it could not be verified, also when
    /// this process refused the record before.
    private func step(refusedFor refusal: DeviceMessageRefusal, _ name: String) -> OpeningRequest.Step {
        guard !Self.unverifies(refusal), !unverifiedRecords.contains(name) else { return .unverified }
        return .ended(endedRequest(name))
    }

    private static func unverifies(_ refusal: DeviceMessageRefusal) -> Bool {
        refusal != .expired && refusal != .replayed
    }

    /// Keeps the names of records refused in this process for anything but
    /// age or a repeat, so a tapped notification for one that is gone says
    /// it could not be verified rather than that it ended.
    private func noteRefusals(_ outcomes: [String: InboxMessageOutcome]) {
        for (name, outcome) in outcomes.sorted(by: { $0.key < $1.key }) {
            guard case .refused(let refusal) = outcome, Self.unverifies(refusal),
                  !unverifiedRecords.contains(name) else { continue }
            unverifiedRecords.append(name)
        }
        if unverifiedRecords.count > Self.pushHintLimit {
            unverifiedRecords.removeFirst(unverifiedRecords.count - Self.pushHintLimit)
        }
    }

    /// How the tapped request ended, from its stored request when the app
    /// holds one, with this iPhone's own name for the Mac. Nil otherwise: a
    /// terminal marker keeps no outcome, and a record that was not found
    /// says nothing about how it ended.
    func endedRequest(_ recordName: String) -> EndedRequest? {
        guard let index = approvals.index(of: recordName) else { return nil }
        let entry = approvals.requests[index]
        let ending: RequestEnding
        if let closed = entry.closed {
            guard let outcome = RequestOutcome(closed) else { return nil }
            ending = .closed(outcome)
        } else if entry.gone {
            ending = .gone
        } else if environment.clock.now() >= entry.countdownEnd {
            ending = .timedOut
        } else {
            return nil
        }
        guard let mac = DeviceID(text: entry.macID), let device = knownList?.device(mac),
              device.pairingID.rawValue == entry.pairingID else { return nil }
        return EndedRequest(ending: ending, macName: device.displayName)
    }

    /// Waits at least `seconds` before the next fetch by name; a longer wait
    /// already asked for stays.
    func postponeNamedFetches(by seconds: TimeInterval) {
        let requested = environment.clock.now().addingTimeInterval(seconds)
        namedFetchNotBefore = max(namedFetchNotBefore ?? requested, requested)
    }
}

/// What the sheet of a tapped notification shows while its request has no
/// card (#348). Nothing here comes from the notification.
public enum OpeningPhase: Hashable, Sendable {
    /// The app is fetching and verifying the record the notification named.
    case loading
    /// Still loading 3 seconds after the tap.
    case slow
    /// The record could not be fetched: the fetch failed and the pass after
    /// it found no card, nothing settled within 15 seconds, or iCloud is
    /// unavailable. Try Again fetches it again.
    case failed
    /// Handled without a card, not found, expired, or already handled by
    /// another fetch: the request ended, as far as the app knows; how, when
    /// it holds the request.
    case ended(EndedRequest?)
    /// Refused for anything but age or a repeat, now or earlier in this
    /// process, or the name is not a message ID.
    case unverified
}

/// How a request the app holds ended, for the ended page: the outcome
/// page's ending and this iPhone's own name for the Mac (#348).
public struct EndedRequest: Hashable, Sendable {
    public let ending: RequestEnding
    public let macName: String

    public init(ending: RequestEnding, macName: String) {
        self.ending = ending
        self.macName = macName
    }
}

/// A tapped notification's record while its request has no card (#337).
/// Only the record name comes from the notification, whose text is never
/// shown; the card appears only once the app verified the request itself.
public struct OpeningRequest: Hashable, Sendable {
    enum Step: Hashable, Sendable {
        /// Its own fetch by name is due at `nextAttempt`.
        case fetchDue
        case fetching
        /// Handled without a card, or not found.
        case ended(EndedRequest?)
        /// Refused, or the name is not a message ID.
        case unverified
    }

    /// The page of a notification whose record name is not a message ID.
    static let unverifiedID = "unverified-notification"
    /// The placeholder appears only this long after the tap.
    static let placeholderDelay: TimeInterval = 0.3
    /// Still loading this long after the tap: slow.
    static let slowAfter: TimeInterval = 3
    /// Nothing settled this long after the tap: failed.
    static let failedAfter: TimeInterval = 15

    /// The record name.
    public let id: String
    /// When the notification was tapped, or Try Again.
    var since: Date
    var step: Step = .fetchDue
    /// After an answer that settled nothing, the next fetch waits this long.
    var nextAttempt: Date
    /// The last fetch by name failed; the next pass that finds no card
    /// shows the failed page.
    var fetchFailed = false
    /// The page says the record could not be fetched.
    var failed = false

    init(id: String, since: Date, step: Step = .fetchDue) {
        self.id = id
        self.since = since
        self.step = step
        nextAttempt = since
    }

    /// This tap or Try Again.
    var attempt: OpeningAttempt { OpeningAttempt(id: id, since: since) }

    /// The thresholds compare dates, as `changeDates` schedules them.
    public func phase(at now: Date) -> OpeningPhase {
        switch step {
        case .ended(let ended):
            return .ended(ended)
        case .unverified:
            return .unverified
        case .fetchDue, .fetching:
            if failed || now >= since.addingTimeInterval(Self.failedAfter) { return .failed }
            return now >= since.addingTimeInterval(Self.slowAfter) ? .slow : .loading
        }
    }

    func showsPlaceholder(at now: Date) -> Bool {
        now >= since.addingTimeInterval(Self.placeholderDelay)
    }

    /// When the page changes by itself: the placeholder, slow, failed.
    var changeDates: [Date] {
        [Self.placeholderDelay, Self.slowAfter, Self.failedAfter].map { since.addingTimeInterval($0) }
    }

    /// Still fetched by name: not settled, and less than
    /// `AppModel.pendingOpenLifetime` since the tap or Try Again.
    func isFetching(at now: Date) -> Bool {
        (step == .fetchDue || step == .fetching) && !hasExpired(at: now)
    }

    func hasExpired(at now: Date) -> Bool {
        now >= since.addingTimeInterval(AppModel.pendingOpenLifetime)
    }
}

/// One tap or Try Again of a tapped notification's record.
struct OpeningAttempt: Hashable, Sendable {
    let id: String
    let since: Date
}
