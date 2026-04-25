import Foundation

// MARK: - SenseAdapter protocol
//
// Per `docs/designs/os-sense.md` §"SenseAdapter 协议".
//
// Stage 0 carve-out:
// The design's full signature is
//     `func attach(hub: AXObserverHub, target: RunningApp) -> AsyncStream<[BehaviorEnvelope]>`
// However, `AXObserverHub` is an OS Sense **Stage 1** module and is intentionally
// not part of this package round (per the no-stub / no-temp-modules rule).
// To keep the protocol compilable without forward-referencing a missing type,
// the `hub:` parameter is omitted at Stage 0.
//
// Stage 1 will introduce `AXObserverHub` and the protocol signature will gain
// a `hub:` argument then. Because zero adapters exist in this round, the
// signature change is non-breaking for any downstream code today.

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

    /// Stage 0: subscribe to AX (or other) signals for `target` and emit the
    /// adapter's full envelope set on each change. Each emission **replaces**
    /// the previous set (not appended).
    ///
    /// Stage 1 will prepend `hub: AXObserverHub` to the parameter list.
    func attach(target: RunningApp) -> AsyncStream<[BehaviorEnvelope]>

    /// Called when `target` leaves the foreground; adapter must release all
    /// subscriptions / observers it holds.
    func detach() async
}
