import Foundation
import AppKit

// MARK: - WindowMirror
//
// Per `docs/designs/os-sense.md` §"事件源与字段映射" row "前台 app 切换".
// Stage 0 watches **only** `NSWorkspace.didActivateApplicationNotification`
// and projects the activated `NSRunningApplication` into `(AppIdentity,
// WindowIdentity)`.
//
// Stage 0 limitation (degraded path, NOT a stub — this is the design's
// degraded mode for "no Accessibility permission / no AX hub yet"):
//   - `WindowIdentity.windowId` is always `nil`
//   - `WindowIdentity.title` falls back to the app's localizedName
// AX-driven window title tracking + `_AXUIElementGetWindow` resolution
// belong to Stage 1 (AXObserverHub). When Stage 1 lands, `WindowMirror`
// gains AX subscription; the chip UI degrades gracefully today per
// the design's "Notch UI 渲染契约".

@MainActor
public final class WindowMirror {
    public private(set) var app: AppIdentity?
    public private(set) var window: WindowIdentity?

    private let onChange: (AppIdentity?, WindowIdentity?) async -> Void
    private let selfBundleId: String?
    private var observer: NSObjectProtocol?

    public init(
        selfBundleId: String? = Bundle.main.bundleIdentifier,
        onChange: @escaping (AppIdentity?, WindowIdentity?) async -> Void
    ) {
        self.selfBundleId = selfBundleId
        self.onChange = onChange
    }

    public func start() {
        // Initial read so chip UI is populated before the first activation event.
        // If the frontmost app at launch is AOS itself (e.g. user clicked the
        // notch before any other app activation), skip — context should
        // describe the user's environment, not us.
        applyFrontmost(NSWorkspace.shared.frontmostApplication)

        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let runningApp = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor in self.applyFrontmost(runningApp) }
        }
    }

    public func stop() {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observer = nil
    }

    private func applyFrontmost(_ runningApp: NSRunningApplication?) {
        // Self-activation suppression: the notch is part of AOS, so clicking
        // it activates `com.aos.shell`. The user's intent is "show me the
        // context of what I was just looking at", not "show me AOS". Drop
        // the event and keep the prior projection.
        if let bundleId = runningApp?.bundleIdentifier,
           let selfBundleId,
           bundleId == selfBundleId {
            return
        }
        let projection = Self.project(runningApp: runningApp)
        self.app = projection.app
        self.window = projection.window
        let captured = projection
        Task { await self.onChange(captured.app, captured.window) }
    }

    /// Pure projection helper, exposed `internal` so unit tests can cover
    /// the bundleId / localizedName / icon-passthrough rules without
    /// fabricating an `NSRunningApplication` (which is not constructible
    /// in tests).
    internal nonisolated static func project(
        runningApp: NSRunningApplication?
    ) -> (app: AppIdentity?, window: WindowIdentity?) {
        guard let runningApp,
              let bundleId = runningApp.bundleIdentifier
        else {
            return (nil, nil)
        }
        let name = runningApp.localizedName ?? bundleId
        let identity = AppIdentity(
            bundleId: bundleId,
            name: name,
            pid: runningApp.processIdentifier,
            icon: runningApp.icon
        )
        let win = WindowIdentity(title: name, windowId: nil)
        return (identity, win)
    }

    /// Test-only entry to drive the writer side without an NSWorkspace event.
    internal func _applyFrontmostForTesting(_ runningApp: NSRunningApplication?) {
        applyFrontmost(runningApp)
    }
}
