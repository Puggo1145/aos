import Foundation

// MARK: - SenseAdapter protocol
//
// Per `docs/designs/os-sense.md` §"SenseAdapter 协议".
//
// `attach` is the seam where adapters subscribe to AX (or other) signals
// for `target`. Adapters MUST go through the shared `AXObserverHub` for
// any AX subscription so observer lifetimes are managed in one place
// (design §"共享 AX 底座"). Each yield from the returned stream is the
// adapter's **complete** current envelope set — `SenseStore` replaces
// the slot wholesale, never appends.
//
// `hub` is `@MainActor`-isolated; an actor adapter calling into it must
// `await`. That's the design intent: the hub serializes AX observer
// mutations behind one isolation boundary.

public typealias AdapterID = String

/// A frontmost-app target handed to an adapter at attach time.
public struct RunningApp: Sendable, Equatable {
    public let bundleId: String
    public let pid: pid_t

    public init(bundleId: String, pid: pid_t) {
        self.bundleId = bundleId
        self.pid = pid
    }
}

public protocol SenseAdapter: Actor {
    static var id: AdapterID { get }
    static var supportedBundleIds: Set<String> { get }
    var requiredPermissions: Set<Permission> { get }

    /// Subscribe to AX (or other) signals for `target` via the shared `hub`
    /// and return an `AsyncStream` of full envelope sets. Each emission
    /// **replaces** the previous set in `SenseStore`'s `behaviorsBySource`.
    /// `async` because the typical implementation does `await hub.subscribe(...)`
    /// and internal AX reads before establishing the stream.
    func attach(hub: AXObserverHub, target: RunningApp) async -> AsyncStream<[BehaviorEnvelope]>

    /// Called when `target` leaves the foreground; adapter must release all
    /// subscriptions / observers it holds via the hub.
    func detach() async
}
