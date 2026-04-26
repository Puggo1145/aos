import Foundation
import AppKit

// MARK: - SenseStore
//
// Per `docs/designs/os-sense.md` §"核心范式：live state mirror" and §"架构总览".
// Single owner of `SenseContext`; all writes funneled through @MainActor
// helpers. Producers (WindowMirror, GeneralProbe, registered adapters) push
// field-scoped updates; this class composes them into the canonical context.
//
// Clipboard is intentionally NOT a live producer: per design §"Clipboard
// capture" the pasteboard is sampled by the Shell composer at user-paste
// time. SenseStore therefore has no `clipboard` field and no polling loop.
//
// Multi-source `behaviors` slot (§"事件源与字段映射"): GeneralProbe + each
// adapter contributes a complete envelope set keyed by source id; the store
// merges them at every write so removing a source is just "forget that key".
// Order: general first, then adapters in registration order — keeps the
// chip row visually stable across app switches.
//
// Adapter plumbing (§"SenseAdapter 协议", §"加新 adapter 的成本"): on every
// frontmost change, the store queries `AdapterRegistry` for adapters whose
// `supportedBundleIds` cover the new app, attaches each (with a 500ms
// timeout + failure isolation per the design) and consumes the
// `AsyncStream<[BehaviorEnvelope]>` they return into `applyBehaviors`. App
// switches detach previous adapters before attaching new ones; concurrent
// swaps are serialized so cancellations don't tear adapter state.
//
// Visual fallback is **on demand**, not a live field. Submit-time capture
// only — see `captureVisualSnapshot()`. Continuous SCStream was rejected
// because it's the heaviest piece of background work in the read-side
// pipeline and the visual is only consumed at submit. The design doc was
// updated to match.
//
// Permission live-tracking: SwiftUI's `@Observable` change-tracking is used
// to react to PermissionsService updates without polling — when accessibility
// flips on, the probe + WindowMirror's AX side attach to the current app
// without restart, matching design §"权限".

@MainActor
@Observable
public final class SenseStore {
    public private(set) var context: SenseContext = .empty

    private let permissionsService: PermissionsService
    private let registry: AdapterRegistry
    private let hub: AXObserverHub
    private let screenMirror: ScreenMirror

    private var windowMirror: WindowMirror?
    private var generalProbe: GeneralProbe?

    /// Behaviors contributed per producer. Key "general" is GeneralProbe;
    /// adapters use their `AdapterID`. Empty arrays remove the entry so the
    /// merged list collapses cleanly when a producer goes quiet.
    private var behaviorsBySource: [String: [BehaviorEnvelope]] = [:]

    /// Adapters currently attached to the frontmost app, keyed by AdapterID.
    private var attachedAdapters: [AdapterID: any SenseAdapter] = [:]
    /// Consumer tasks for each attached adapter's AsyncStream. Cancel +
    /// await on detach.
    private var adapterTasks: [AdapterID: Task<Void, Never>] = [:]
    /// Single in-flight adapter swap task. New swaps await the previous one
    /// before running so detach/attach pairs never interleave.
    private var pendingSwap: Task<Void, Never>?

    public init(permissionsService: PermissionsService, registry: AdapterRegistry) {
        self.permissionsService = permissionsService
        self.registry = registry
        self.hub = AXObserverHub()
        self.screenMirror = ScreenMirror()
    }

    public func start() async {
        await permissionsService.refresh()
        applyPermissions(permissionsService.state)

        // Producers are constructed once; their lifecycles are driven by
        // app/permission changes, not by start/stop pairs.
        let probe = GeneralProbe(hub: hub) { [weak self] envelopes in
            self?.applyBehaviors(source: "general", envelopes: envelopes)
        }
        self.generalProbe = probe

        let windowMirror = WindowMirror(hub: hub) { [weak self] app, window in
            self?.applyFrontmost(app: app, window: window)
        }
        windowMirror.setAccessibilityGranted(
            !permissionsService.state.denied.contains(.accessibility)
        )
        self.windowMirror = windowMirror
        windowMirror.start()

        observePermissions()
    }

    public func stop() {
        windowMirror?.stop()
        windowMirror = nil
        generalProbe?.detach()
        generalProbe = nil
        if let pid = context.app?.pid {
            hub.detach(pid: pid)
        }
        behaviorsBySource.removeAll()
        // Tear down adapters. We can't synchronously await detach() of
        // each adapter from a non-async stop(), so schedule it on the
        // pending-swap chain — the chain's "previous swap finishes first"
        // ordering still holds.
        scheduleAdapterDetachAll()
    }

    // MARK: - Visual snapshot (on demand)
    //
    // Called at submit time by the Shell when the visual chip is selected.
    // Single async capture — no background loop. Returns nil if no frontmost
    // app, screen recording is denied, or capture itself fails.

    /// Whether a visual snapshot would succeed if requested right now —
    /// frontmost app exists AND screen recording is granted. Drives the UI
    /// chip's visibility so we don't show "Window snapshot" when it'd be
    /// guaranteed to come back nil.
    public var visualSnapshotAvailable: Bool {
        context.app != nil
            && !context.permissions.denied.contains(.screenRecording)
    }

    /// Capture a single fresh window screenshot for the current frontmost app.
    /// Bypasses the AX behaviors gate — the caller decides whether to use it
    /// (typically: only when `behaviors` is empty, but we don't enforce that
    /// here).
    public func captureVisualSnapshot() async -> VisualMirror? {
        guard let pid = context.app?.pid else { return nil }
        guard !context.permissions.denied.contains(.screenRecording) else { return nil }
        return await screenMirror.captureNow(forPid: pid)
    }

    // MARK: - Field writers (single-writer invariant)

    private func applyFrontmost(app: AppIdentity?, window: WindowIdentity?) {
        let oldPid = context.app?.pid
        let newPid = app?.pid

        context = SenseContext(
            app: app,
            window: window,
            behaviors: context.behaviors,
            permissions: context.permissions
        )

        // App changed: tear down all per-pid AX state and any adapter envelopes
        // that were associated with the old app.
        if oldPid != newPid {
            generalProbe?.detach()
            if let oldPid {
                hub.detach(pid: oldPid)
            }
            if !behaviorsBySource.isEmpty {
                behaviorsBySource.removeAll()
                applyBehaviorsRecompute()
            }
            // Swap adapters for the new bundle id. Sequenced through
            // pendingSwap so detach/attach never overlap.
            scheduleAdapterSwap()
        }

        // Attach probe to the new app iff Accessibility is granted.
        if let newPid,
           !context.permissions.denied.contains(.accessibility) {
            generalProbe?.attach(pid: newPid)
        }
    }

    private func applyBehaviors(source: String, envelopes: [BehaviorEnvelope]) {
        if envelopes.isEmpty {
            behaviorsBySource.removeValue(forKey: source)
        } else {
            behaviorsBySource[source] = envelopes
        }
        applyBehaviorsRecompute()
    }

    private func applyBehaviorsRecompute() {
        let merged = mergeBehaviors()
        context = SenseContext(
            app: context.app,
            window: context.window,
            behaviors: merged,
            permissions: context.permissions
        )
    }

    private func mergeBehaviors() -> [BehaviorEnvelope] {
        var out: [BehaviorEnvelope] = []
        if let general = behaviorsBySource["general"] {
            out.append(contentsOf: general)
        }
        // Adapters in iteration order. Stable enough for now; Stage 2 can
        // pin a registration-order array on AdapterRegistry if needed.
        for (key, value) in behaviorsBySource where key != "general" {
            out.append(contentsOf: value)
        }
        return out
    }

    private func applyPermissions(_ permissions: PermissionState) {
        let oldDenied = context.permissions.denied
        context = SenseContext(
            app: context.app,
            window: context.window,
            behaviors: context.behaviors,
            permissions: permissions
        )

        let axNowGranted = oldDenied.contains(.accessibility)
            && !permissions.denied.contains(.accessibility)
        let axNowRevoked = !oldDenied.contains(.accessibility)
            && permissions.denied.contains(.accessibility)

        if axNowGranted, let pid = context.app?.pid {
            generalProbe?.attach(pid: pid)
        }
        if axNowRevoked {
            generalProbe?.detach()
            if let pid = context.app?.pid {
                hub.detach(pid: pid)
            }
        }
        // Keep WindowMirror's AX-side hookup in sync. Re-emits with AX-
        // resolved or degraded window as appropriate.
        if axNowGranted || axNowRevoked {
            windowMirror?.setAccessibilityGranted(!permissions.denied.contains(.accessibility))
        }
    }

    /// Re-arm Observable tracking of `permissionsService.state`. Each fire
    /// re-applies the state and re-arms the tracker for the next change.
    private func observePermissions() {
        withObservationTracking {
            _ = permissionsService.state
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.applyPermissions(self.permissionsService.state)
                self.observePermissions()
            }
        }
    }

    // MARK: - Adapter swap pipeline
    //
    // Each frontmost change kicks off an async swap: detach previous
    // adapters, then attach all adapters matching the new bundle id. Swaps
    // are chained through `pendingSwap` so an in-flight detach can't race
    // with the next attach — the cost is a few extra ms when the user
    // app-switches rapidly, the win is no torn adapter state.

    private func scheduleAdapterSwap() {
        let previous = pendingSwap
        pendingSwap = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await self.detachAllAdapters()
            await self.attachAdaptersForCurrentApp()
        }
    }

    private func scheduleAdapterDetachAll() {
        let previous = pendingSwap
        pendingSwap = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await self.detachAllAdapters()
        }
    }

    private func detachAllAdapters() async {
        let toDetach = attachedAdapters
        let tasks = adapterTasks
        attachedAdapters.removeAll()
        adapterTasks.removeAll()

        // Drop each adapter's contribution from the merged behaviors view
        // immediately so the UI doesn't show stale chips.
        var changed = false
        for id in toDetach.keys where behaviorsBySource[id] != nil {
            behaviorsBySource.removeValue(forKey: id)
            changed = true
        }
        if changed {
            applyBehaviorsRecompute()
        }

        // Cancel consumer tasks first so we stop reading from streams the
        // adapter is about to tear down.
        for (_, task) in tasks { task.cancel() }

        // Tell each adapter to release its hub subscriptions. Run in
        // parallel — adapters are independent and detach() should be
        // quick.
        await withTaskGroup(of: Void.self) { group in
            for (_, adapter) in toDetach {
                group.addTask { await adapter.detach() }
            }
        }
    }

    private func attachAdaptersForCurrentApp() async {
        guard let app = context.app else { return }
        let bundleId = app.bundleId
        let target = RunningApp(bundleId: bundleId, pid: app.pid)
        let denied = context.permissions.denied
        let candidates = await registry.adapters(matching: bundleId)
        let hubRef = self.hub

        for adapter in candidates {
            let required = await adapter.requiredPermissions
            // Permission isolation: skip attach when any required permission
            // is currently denied (design §"权限隔离"). The chip / adapter
            // re-attaches automatically once permissions flip — the next
            // applyPermissions tick re-runs swap.
            guard required.isDisjoint(with: denied) else { continue }
            let id = type(of: adapter).id
            // 500ms timeout + failure isolation (design §"SenseAdapter 协议":
            // "失败让该 adapter 输出空 behavior 集合，不影响其他来源").
            let stream = await Self.withAttachTimeout(
                milliseconds: 500,
                attach: { await adapter.attach(hub: hubRef, target: target) }
            )
            guard let stream else { continue }

            attachedAdapters[id] = adapter
            let consumer = Task { [weak self] in
                for await envelopes in stream {
                    if Task.isCancelled { return }
                    guard let self else { return }
                    self.applyBehaviors(source: id, envelopes: envelopes)
                }
            }
            adapterTasks[id] = consumer
        }
    }

    /// Race the adapter's `attach` call against a sleep. If `attach` returns
    /// first, that stream is the result; if the sleep wins, the adapter is
    /// considered failed and we return nil (the adapter task that's still
    /// running will be cancelled when the group tears down).
    private static func withAttachTimeout(
        milliseconds: Int,
        attach: @escaping @Sendable () async -> AsyncStream<[BehaviorEnvelope]>
    ) async -> AsyncStream<[BehaviorEnvelope]>? {
        await withTaskGroup(of: AsyncStream<[BehaviorEnvelope]>?.self) { group in
            group.addTask { await attach() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    // MARK: - Test seams (internal; reached via @testable import)

    internal func _applyFrontmostForTesting(app: AppIdentity?, window: WindowIdentity?) {
        applyFrontmost(app: app, window: window)
    }

    internal func _applyPermissionsForTesting(_ permissions: PermissionState) {
        applyPermissions(permissions)
    }

    internal func _applyBehaviorsForTesting(source: String, envelopes: [BehaviorEnvelope]) {
        applyBehaviors(source: source, envelopes: envelopes)
    }

    internal var _behaviorsBySourceForTesting: [String: [BehaviorEnvelope]] {
        behaviorsBySource
    }

    /// Test-only: wait for any in-flight adapter swap to complete. Lets
    /// tests assert post-swap state without sleeping.
    internal func _awaitPendingAdapterSwapForTesting() async {
        await pendingSwap?.value
    }

    internal var _attachedAdapterIdsForTesting: Set<AdapterID> {
        Set(attachedAdapters.keys)
    }
}
