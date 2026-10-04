import CryptoKit
import Darwin
import Foundation

/// Short-lived routing metadata shared by separate command-hook processes.
/// Only hashes, timestamps and completion flags reach disk. This is not an
/// authorization store and never participates in Broker credential decisions.
struct DiscoveryTurnStore {
    enum Phase { case before, after }
    enum Failure: Error { case unsafe, busy, invalid }
    private struct Turn: Codable {
        var pending: Set<String> = []
        var completed = false
        var touched: TimeInterval
    }
    private struct Generation: Codable { var key: String; var touched: TimeInterval }
    private struct State: Codable {
        var turns: [String: Turn] = [:]
        var grokTurns: [String: Generation] = [:]
        var grokCalls: [String: Generation] = [:]
        // Optional fields keep existing Cursor/Grok state readable.
        var claudeTurns: [String: Generation]?
        var claudeCalls: [String: Generation]?
    }
    let directory: URL

    func beginClaudeTurn(session: String) throws {
        guard !session.isEmpty, session.utf8.count <= 4096 else { throw Failure.invalid }
        try withState { state in
            var turns = state.claudeTurns ?? [:]
            turns[Self.hash(["claude", session])] = Generation(
                key: UUID().uuidString, touched: Date().timeIntervalSince1970
            )
            state.claudeTurns = turns
        }
    }

    func beginGrokTurn(session: String, promptID: String) throws {
        guard !session.isEmpty, !promptID.isEmpty, session.utf8.count <= 4096,
              promptID.utf8.count <= 4096 else { throw Failure.invalid }
        try withState { state in
            state.grokTurns[Self.hash(["grok", session])] = Generation(
                key: Self.hash(["grok", session, promptID]), touched: Date().timeIntervalSince1970
            )
        }
    }

    func catalogAttemptSettled(client: String, session: String, turn: String?,
                          callID: String?, phase: Phase, catalog: Bool) throws -> Bool {
        guard !session.isEmpty, session.utf8.count <= 4096,
              (turn?.utf8.count ?? 0) <= 4096, (callID?.utf8.count ?? 0) <= 4096 else { throw Failure.invalid }
        return try withState { state in
            let now = Date().timeIntervalSince1970
            state.turns = state.turns.filter { now - $0.value.touched < 86_400 }
            let key: String
            let call = callID.map { Self.hash([client, session, $0]) }
            if let turn, !turn.isEmpty {
                key = Self.hash([client, session, turn])
            } else if client == "grok" {
                if catalog, phase == .after, let call {
                    // A late result belongs to the turn in which it started,
                    // not whichever prompt is active when it finishes.
                    guard let pending = state.grokCalls.removeValue(forKey: call) else { return false }
                    key = pending.key
                } else {
                    let sessionKey = Self.hash([client, session])
                    if state.grokTurns[sessionKey] == nil {
                        state.grokTurns[sessionKey] = Generation(key: UUID().uuidString, touched: now)
                    }
                    key = state.grokTurns[sessionKey]!.key
                    if catalog, let call { state.grokCalls[call] = Generation(key: key, touched: now) }
                }
            } else if client == "claude" {
                var turns = state.claudeTurns ?? [:]
                var calls = state.claudeCalls ?? [:]
                if catalog, phase == .after, let call {
                    guard let pending = calls.removeValue(forKey: call) else { return false }
                    key = pending.key
                } else {
                    let sessionKey = Self.hash([client, session])
                    if turns[sessionKey] == nil {
                        turns[sessionKey] = Generation(key: UUID().uuidString, touched: now)
                    }
                    key = turns[sessionKey]!.key
                    if catalog, let call { calls[call] = Generation(key: key, touched: now) }
                }
                state.claudeTurns = turns
                state.claudeCalls = calls
            } else { throw Failure.invalid }
            var entry = state.turns[key] ?? Turn(touched: now)
            if state.turns[key] == nil { state.turns[key] = entry }
            if catalog, let callID, !callID.isEmpty, let call {
                switch phase {
                case .before:
                    if entry.pending.count < 64 { entry.pending.insert(call) }
                case .after:
                    if entry.pending.remove(call) != nil { entry.completed = true }
                }
                entry.touched = now
                state.turns[key] = entry
            }
            if state.turns.count > 256 {
                for key in state.turns.sorted(by: { $0.value.touched < $1.value.touched })
                    .prefix(state.turns.count - 256).map(\.key) {
                    state.turns.removeValue(forKey: key)
                }
            }
            // Missing tools and lost post callbacks must not turn a routing
            // reminder into a permanent execution barrier. After 30 seconds
            // without catalog progress, continue with normal client/Broker
            // permissions. Do not falsely record a completed catalog lookup.
            return entry.completed || now - entry.touched >= 30
        }
    }

    private static func hash(_ components: [String]) -> String {
        let bytes = (try? JSONEncoder().encode(components)) ?? Data()
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private func withState<T>(_ update: (inout State) throws -> T) throws -> T {
        if mkdir(directory.path, 0o700) != 0, errno != EEXIST { throw Failure.unsafe }
        let dir = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dir >= 0 else { throw Failure.unsafe }
        defer { close(dir) }
        var info = stat()
        guard fstat(dir, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o777 == 0o700 else {
            throw Failure.unsafe
        }
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var managed = directory
        try managed.setResourceValues(resourceValues)
        let lock = openat(dir, "lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard lock >= 0 else { throw Failure.unsafe }
        defer { close(lock) }
        try Self.validate(lock)
        let deadline = ProcessInfo.processInfo.systemUptime + 0.2
        while flock(lock, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR else { throw Failure.unsafe }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw Failure.busy }
            usleep(5_000)
        }
        defer { flock(lock, LOCK_UN) }
        let original = try Self.readState(dir)
        var state = original.isEmpty ? State() : try JSONDecoder().decode(State.self, from: original)
        let result = try update(&state)
        let cutoff = Date().timeIntervalSince1970 - 86_400
        for isCalls in [false, true] {
            var entries = isCalls ? state.grokCalls : state.grokTurns
            entries = entries.filter { $0.value.touched > cutoff }
            for key in entries.sorted(by: { $0.value.touched < $1.value.touched })
                .prefix(max(0, entries.count - 512)).map(\.key) { entries.removeValue(forKey: key) }
            if isCalls { state.grokCalls = entries } else { state.grokTurns = entries }
        }
        for isCalls in [false, true] {
            guard var entries = isCalls ? state.claudeCalls : state.claudeTurns else { continue }
            entries = entries.filter { $0.value.touched > cutoff }
            for key in entries.sorted(by: { $0.value.touched < $1.value.touched })
                .prefix(max(0, entries.count - 512)).map(\.key) { entries.removeValue(forKey: key) }
            if isCalls { state.claudeCalls = entries } else { state.claudeTurns = entries }
        }
        let next = try JSONEncoder().encode(state)
        guard next.count <= 1_048_576 else { throw Failure.invalid }
        if next != original { try Self.writeState(next, directory: dir) }
        return result
    }

    private static func validate(_ fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1, info.st_mode & 0o777 == 0o600 else { throw Failure.unsafe }
    }

    private static func readState(_ directory: Int32) throws -> Data {
        let fd = openat(directory, "state.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if fd < 0, errno == ENOENT { return Data() }
        guard fd >= 0 else { throw Failure.unsafe }
        defer { close(fd) }
        try validate(fd)
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count == 0 { return bytes }
            if count < 0, errno == EINTR { continue }
            guard count > 0, bytes.count + count <= 1_048_576 else { throw Failure.invalid }
            bytes.append(buffer, count: count)
        }
    }

    private static func writeState(_ bytes: Data, directory: Int32) throws {
        let name = ".pending-\(UUID().uuidString)"
        let fd = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.unsafe }
        defer { close(fd); unlinkat(directory, name, 0) }
        try bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw Failure.unsafe }
                offset += count
            }
        }
        guard fsync(fd) == 0, renameat(directory, name, directory, "state.json") == 0 else {
            throw Failure.unsafe
        }
    }
}
