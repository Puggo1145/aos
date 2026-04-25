import Foundation
import AppKit

// MARK: - SenseStore
//
// Per `docs/designs/os-sense.md` §"核心范式：live state mirror" and the
// approved Stage 0 scope row in `agents-md-notch-ui-crispy-horizon.md` §G.
//
// Concurrency model decision: the design names this an `actor`, but the
// invariant the design actually requires is "single writer + serialized
// writes + Observable to UI". On macOS 14, `@MainActor @Observable`
// satisfies all three: every mutation is funneled through private setters
// inside MainActor isolation, and SwiftUI views can `@Bindable` directly
// against `context`. This is functionally equivalent to the design's actor
// requirement while removing the actor-hop friction at the UI bind seam.
//
// Stage 0 scope: only `WindowMirror` + `PermissionsService` are wired in.
// `AdapterRegistry` is held but no adapters are registered (design §"加新
// adapter 的成本" explicitly permits zero-adapter state). GeneralProbe /
// ClipboardWatcher / ScreenMirror / AXObserverHub arrive in later stages.

@MainActor
@Observable
public final class SenseStore {
    public private(set) var context: SenseContext = .empty

    private let permissionsService: PermissionsService
    private let registry: AdapterRegistry
    private var windowMirror: WindowMirror?

    public init(permissionsService: PermissionsService, registry: AdapterRegistry) {
        self.permissionsService = permissionsService
        self.registry = registry
    }

    public func start() async {
        await permissionsService.refresh()
        applyPermissions(permissionsService.state)

        let mirror = WindowMirror { [weak self] app, window in
            self?.applyFrontmost(app: app, window: window)
        }
        windowMirror = mirror
        mirror.start()
    }

    public func stop() {
        windowMirror?.stop()
        windowMirror = nil
    }

    // MARK: - Private writers (single-writer invariant)

    private func applyFrontmost(app: AppIdentity?, window: WindowIdentity?) {
        context = SenseContext(
            app: app,
            window: window,
            behaviors: context.behaviors,
            visual: context.visual,
            clipboard: context.clipboard,
            permissions: context.permissions
        )
        // Stage 1+: route the new app through `registry.adapters(matching:)`
        // and attach. Zero adapters this round, so nothing to do here.
    }

    private func applyPermissions(_ permissions: PermissionState) {
        context = SenseContext(
            app: context.app,
            window: context.window,
            behaviors: context.behaviors,
            visual: context.visual,
            clipboard: context.clipboard,
            permissions: permissions
        )
    }

    // MARK: - Test-only entries
    //
    // Marked `internal` and reached via `@testable import AOSOSSenseKit`.
    // Production callers go through `start()` and the WindowMirror callback;
    // tests need direct access to assert single-writer projection rules.

    internal func _applyFrontmostForTesting(app: AppIdentity?, window: WindowIdentity?) {
        applyFrontmost(app: app, window: window)
    }

    internal func _applyPermissionsForTesting(_ permissions: PermissionState) {
        applyPermissions(permissions)
    }
}
