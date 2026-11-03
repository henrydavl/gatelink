import Foundation
@testable import GateLinkKit

/// A clock the tests advance by hand. `sleep` suspends until the clock is
/// advanced past its deadline, or the sleeping task is cancelled.
final class TestClock: @unchecked Sendable {
    private struct Sleeper {
        var id: UUID
        var deadline: Date
        var continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var current: Date
    private var sleepers: [Sleeper] = []
    private var cancelledIDs: Set<UUID> = []

    /// 15 seconds into a 30-second OTP step.
    init(_ start: Date = Date(timeIntervalSince1970: 1_000_000_005)) {
        current = start
    }

    var now: Date { lock.withLock { current } }

    var pendingSleeps: Int { lock.withLock { sleepers.count } }

    func advance(by seconds: TimeInterval) {
        let ready: [Sleeper] = lock.withLock {
            current = current.addingTimeInterval(seconds)
            let due = sleepers.filter { $0.deadline <= current }
            sleepers.removeAll { $0.deadline <= current }
            return due
        }
        ready.forEach { $0.continuation.resume() }
    }

    /// Jumps to the earliest pending deadline. False when nothing sleeps.
    @discardableResult
    func advanceToNextDeadline() -> Bool {
        let next: Date? = lock.withLock { sleepers.map(\.deadline).min() }
        guard let next else { return false }
        advance(by: max(0, next.timeIntervalSince(now)))
        return true
    }

    func sleep(_ seconds: TimeInterval) async throws {
        try Task.checkCancellation()
        guard seconds > 0 else { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.withLock {
                    if cancelledIDs.remove(id) != nil {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        sleepers.append(Sleeper(id: id, deadline: current.addingTimeInterval(seconds), continuation: continuation))
                    }
                }
            }
        } onCancel: {
            let sleeper: Sleeper? = lock.withLock {
                guard let index = sleepers.firstIndex(where: { $0.id == id }) else {
                    cancelledIDs.insert(id)
                    return nil
                }
                return sleepers.remove(at: index)
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }
}

final class CountingVerifier: UserPresenceVerifier, @unchecked Sendable {
    private let lock = NSLock()
    private var _prompts = 0
    var answer = true

    var prompts: Int { lock.withLock { _prompts } }

    func verify(reason: String) async -> Bool {
        lock.withLock { _prompts += 1 }
        return answer
    }
}

actor FakeAuthenticator: VPNAuthenticator {
    struct Call: Equatable {
        var gateway: String
        var username: String
        var credential: String
    }

    private(set) var calls: [Call] = []
    var result: Result<GPCookie, GateLinkError> = .success(
        GPCookie(cookie: "authcookie=abc", host: "203.0.113.10", fingerprint: "pin-sha256:AbC=")
    )
    private var gate: CheckedContinuation<Void, Never>?
    private var holdNext = false

    func setResult(_ result: Result<GPCookie, GateLinkError>) { self.result = result }

    /// The next call suspends until `release()`.
    func hold() { holdNext = true }

    func release() {
        gate?.resume()
        gate = nil
    }

    func authenticate(gateway: String, username: String, credential: String) async throws -> GPCookie {
        calls.append(Call(gateway: gateway, username: username, credential: credential))
        if holdNext {
            holdNext = false
            await withCheckedContinuation { gate = $0 }
        }
        try Task.checkCancellation()
        return try result.get()
    }
}

actor FakeTunnel: TunnelController {
    struct Start: Equatable {
        var host: String
        var fingerprint: String
        var cookie: String
    }

    private(set) var starts: [Start] = []
    private(set) var stops = 0
    private var continuation: AsyncStream<TunnelEvent>.Continuation?
    private var startWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func start(host: String, fingerprint: String, cookie: String) async throws -> AsyncStream<TunnelEvent> {
        starts.append(Start(host: host, fingerprint: fingerprint, cookie: cookie))
        let (stream, continuation) = AsyncStream<TunnelEvent>.makeStream()
        self.continuation = continuation
        let ready = startWaiters.filter { $0.count <= starts.count }
        startWaiters.removeAll { $0.count <= starts.count }
        ready.forEach { $0.continuation.resume() }
        return stream
    }

    func stop() async {
        stops += 1
        continuation?.finish()
        continuation = nil
    }

    func emit(_ event: TunnelEvent) {
        continuation?.yield(event)
        if case .exited = event {
            continuation?.finish()
            continuation = nil
        }
    }

    /// Suspends until `start` has been called `count` times in total.
    func waitForStart(_ count: Int = 1) async {
        if starts.count >= count { return }
        await withCheckedContinuation { startWaiters.append((count, $0)) }
    }
}

/// Polls `condition` on the main actor until it holds or 2 seconds pass.
@MainActor
func eventually(_ condition: @MainActor () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

/// Like `eventually`, but fast-forwards `clock` through pending sleeps
/// (reconnect delays, OTP rollovers) while waiting.
@MainActor
func drive(_ clock: TestClock, until condition: @MainActor () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
        if await condition() { return true }
        clock.advanceToNextDeadline()
    }
    return await condition()
}
