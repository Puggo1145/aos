import Foundation
import AppKit
import ApplicationServices
import ScreenCaptureKit

// MARK: - PermissionsService
//
// Per `docs/designs/os-sense.md` §"权限". This is the Shell-level single
// source of truth for runtime permissions consumed by OS Sense (and later
// Computer Use). All probing is centralized here; subsystems read the
// published `state` rather than running their own probes.
//
// Stage 0 probes:
//   - Accessibility:    `AXIsProcessTrusted()` (synchronous, cheap)
//   - Screen Recording: `SCShareableContent.current` (truth source, async).
//                       Cached for 5s to avoid hammering the API.
//   - Automation:       NOT probed this round — no caller. (Apple-Event-using
//                       adapters arrive in Stage 2.) The schema slot is
//                       preserved so Stage 2 can light it up without API churn.

@MainActor
@Observable
public final class PermissionsService {
    public private(set) var state: PermissionState = PermissionState(denied: [])

    private var screenRecordingCache: (granted: Bool, at: Date)?
    private static let screenRecordingCacheTTL: TimeInterval = 5

    public init() {}

    /// Re-probe permissions and publish the resulting state.
    /// Callers (AppDelegate, workspace activation listeners) invoke this on
    /// app launch and on relevant lifecycle events.
    public func refresh() async {
        let axTrusted = AXIsProcessTrusted()
        let screenRecordingGranted = await isScreenRecordingGranted()
        // Automation: not probed this round (no caller).
        state = PermissionState(
            denied: Self.computeDeniedSet(
                axTrusted: axTrusted,
                screenRecordingGranted: screenRecordingGranted
            )
        )
    }

    /// Pure projection used by `refresh()` and unit tests. Keeping this
    /// pure allows tests to cover all combinations without touching real
    /// AX / SCKit APIs.
    internal nonisolated static func computeDeniedSet(
        axTrusted: Bool,
        screenRecordingGranted: Bool
    ) -> Set<Permission> {
        var denied: Set<Permission> = []
        if !axTrusted { denied.insert(.accessibility) }
        if !screenRecordingGranted { denied.insert(.screenRecording) }
        return denied
    }

    private func isScreenRecordingGranted() async -> Bool {
        if let cache = screenRecordingCache,
           Date().timeIntervalSince(cache.at) < Self.screenRecordingCacheTTL {
            return cache.granted
        }
        do {
            _ = try await SCShareableContent.current
            screenRecordingCache = (granted: true, at: Date())
            return true
        } catch {
            screenRecordingCache = (granted: false, at: Date())
            return false
        }
    }
}
