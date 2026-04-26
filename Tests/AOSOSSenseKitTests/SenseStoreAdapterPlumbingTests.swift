import Testing
import Foundation
import CoreGraphics
@testable import AOSOSSenseKit

// MARK: - Mock adapters
//
// Hand-driven SenseAdapter conformances that bypass AX entirely so the
// SenseStore plumbing (attach / detach / consume / timeout / permission
// gating) can be exercised without real AX permissions.

private actor MockAdapter: SenseAdapter {
    static let id: AdapterID = "mock"
    static var supportedBundleIds: Set<String> = ["com.test.app"]
    nonisolated let requiredPermissions: Set<Permission> = []

    private var continuation: AsyncStream<[BehaviorEnvelope]>.Continuation?
    private(set) var attachCount = 0
    private(set) var detachCount = 0

    func attach(hub: AXObserverHub, target: RunningApp) async -> AsyncStream<[BehaviorEnvelope]> {
        attachCount += 1
        var captured: AsyncStream<[BehaviorEnvelope]>.Continuation!
        let stream = AsyncStream<[BehaviorEnvelope]> { c in
            captured = c
        }
        self.continuation = captured
        return stream
    }

    func detach() async {
        detachCount += 1
        continuation?.finish()
        continuation = nil
    }

    func emit(_ envelopes: [BehaviorEnvelope]) {
        continuation?.yield(envelopes)
    }
}

private actor SlowAttachAdapter: SenseAdapter {
    static let id: AdapterID = "slow"
    static var supportedBundleIds: Set<String> = ["com.test.slow"]
    nonisolated let requiredPermissions: Set<Permission> = []

    func attach(hub: AXObserverHub, target: RunningApp) async -> AsyncStream<[BehaviorEnvelope]> {
        // Sleep past the 500ms attach timeout so the store should give up
        // on us. When the surrounding TaskGroup cancels, the sleep throws
        // CancellationError → swallowed, then we still return a stream
        // that nobody is listening to.
        try? await Task.sleep(nanoseconds: 700_000_000)
        return AsyncStream { _ in }
    }

    func detach() async {}
}

private actor PermissionedAdapter: SenseAdapter {
    static let id: AdapterID = "permissioned"
    static var supportedBundleIds: Set<String> = ["com.test.app"]
    nonisolated let requiredPermissions: Set<Permission> = [.automation]

    private(set) var attachCount = 0

    func attach(hub: AXObserverHub, target: RunningApp) async -> AsyncStream<[BehaviorEnvelope]> {
        attachCount += 1
        return AsyncStream { _ in }
    }

    func detach() async {}
}

@MainActor
@Suite("SenseStore — adapter plumbing")
struct SenseStoreAdapterPlumbingTests {

    private func envelope(_ key: String, _ summary: String) -> BehaviorEnvelope {
        BehaviorEnvelope(
            kind: "mock.signal",
            citationKey: key,
            displaySummary: summary,
            payload: .object([:])
        )
    }

    private func makeStore(adapters: [any SenseAdapter] = []) async -> SenseStore {
        let registry = AdapterRegistry()
        for adapter in adapters { await registry.register(adapter) }
        return SenseStore(
            permissionsService: PermissionsService(),
            registry: registry
        )
    }

    @Test("Matching adapter attaches on app activation and emits flow into context")
    func attachAndEmit() async {
        let mock = MockAdapter()
        let store = await makeStore(adapters: [mock])

        store._applyFrontmostForTesting(
            app: AppIdentity(bundleId: "com.test.app", name: "Test", pid: 100, icon: nil),
            window: WindowIdentity(title: "Test", windowId: nil)
        )
        await store._awaitPendingAdapterSwapForTesting()

        #expect(store._attachedAdapterIdsForTesting.contains("mock"))
        let attaches = await mock.attachCount
        #expect(attaches == 1)

        // Drive an emission and confirm it surfaces in context.behaviors.
        await mock.emit([envelope("m:1", "first")])
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(store.context.behaviors.contains { $0.citationKey == "m:1" })
    }

    @Test("App switch detaches the previous adapter and clears its envelopes")
    func detachOnSwitch() async {
        let mock = MockAdapter()
        let store = await makeStore(adapters: [mock])

        store._applyFrontmostForTesting(
            app: AppIdentity(bundleId: "com.test.app", name: "Test", pid: 100, icon: nil),
            window: WindowIdentity(title: "Test", windowId: nil)
        )
        await store._awaitPendingAdapterSwapForTesting()
        await mock.emit([envelope("m:1", "first")])
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(store.context.behaviors.contains { $0.citationKey == "m:1" })

        // Switch to an app whose bundleId nobody covers.
        store._applyFrontmostForTesting(
            app: AppIdentity(bundleId: "com.other.app", name: "Other", pid: 200, icon: nil),
            window: WindowIdentity(title: "Other", windowId: nil)
        )
        await store._awaitPendingAdapterSwapForTesting()

        let detaches = await mock.detachCount
        #expect(detaches == 1)
        #expect(store._attachedAdapterIdsForTesting.isEmpty)
        #expect(store.context.behaviors.isEmpty)
    }

    @Test("Slow attach (>500ms) is treated as a failed adapter — no contribution")
    func slowAttachTimesOut() async {
        let slow = SlowAttachAdapter()
        let store = await makeStore(adapters: [slow])

        store._applyFrontmostForTesting(
            app: AppIdentity(bundleId: "com.test.slow", name: "Slow", pid: 300, icon: nil),
            window: WindowIdentity(title: "Slow", windowId: nil)
        )
        await store._awaitPendingAdapterSwapForTesting()

        // Adapter timed out — never registered as attached, no envelopes
        // contributed. (Failure isolation: other producers, if any, would
        // still work — there are none in this test.)
        #expect(!store._attachedAdapterIdsForTesting.contains("slow"))
        #expect(store.context.behaviors.isEmpty)
    }

    @Test("Adapter requiring a denied permission is skipped at attach")
    func permissionGatedSkip() async {
        let permissioned = PermissionedAdapter()
        let store = await makeStore(adapters: [permissioned])

        store._applyPermissionsForTesting(PermissionState(denied: [.automation]))
        store._applyFrontmostForTesting(
            app: AppIdentity(bundleId: "com.test.app", name: "Test", pid: 400, icon: nil),
            window: WindowIdentity(title: "Test", windowId: nil)
        )
        await store._awaitPendingAdapterSwapForTesting()

        let attaches = await permissioned.attachCount
        #expect(attaches == 0)
        #expect(!store._attachedAdapterIdsForTesting.contains("permissioned"))
    }
}
