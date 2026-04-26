import Testing
import Foundation
import CoreGraphics
import AppKit
import AOSOSSenseKit
@testable import AOSShell

// MARK: - NotchTrayDismissalTests
//
// Covers the tray dismissal state machine on `NotchViewModel`:
//   - dismissNotice(_:) inserts into `dismissedNotices`
//   - dismissing the last visible notice resets `trayExpanded` so the next
//     time a notice arrives the drawer starts collapsed (matches the
//     comment in NotchViewModel.dismissNotice)
//
// Built on top of real services initialized over closed pipes (no actual
// RPC traffic) — same pattern AgentServiceTests uses.

@MainActor
@Suite("Notch tray dismissal")
struct NotchTrayDismissalTests {

    private func makeViewModel() -> NotchViewModel {
        // Real RPCClient over a closed pipe pair — services keep references
        // for handler registration but never make a live request in these
        // tests; we mutate state directly via the public surface.
        let inbound = Pipe()
        let outbound = Pipe()
        let rpc = RPCClient(
            inbound: inbound.fileHandleForReading,
            outbound: outbound.fileHandleForWriting
        )
        let permissions = PermissionsService()
        let registry = AdapterRegistry()
        let sense = SenseStore(permissionsService: permissions, registry: registry)
        let agent = AgentService(rpc: rpc)
        let provider = ProviderService(rpc: rpc)
        let config = ConfigService(rpc: rpc)
        return NotchViewModel(
            senseStore: sense,
            agentService: agent,
            providerService: provider,
            configService: config,
            permissionsService: permissions,
            screenRect: CGRect(x: 0, y: 0, width: 1440, height: 900),
            deviceNotchRect: CGRect(x: 620, y: 868, width: 200, height: 32)
        )
    }

    @Test("freshly-initialised viewmodel surfaces the missing-provider notice")
    func defaultStateHasMissingProviderNotice() {
        let vm = makeViewModel()
        // statusLoaded is false until refreshStatus() succeeds, so the
        // tray's initial state is "no provider configured". Permissions
        // default to allGranted (denied is empty) and config is not
        // corrupted, so this is the only notice.
        let kinds = vm.trayNotices.map(\.kind)
        #expect(kinds == [.missingProvider])
    }

    @Test("dismissNotice records the kind in dismissedNotices")
    func dismissRecordsKind() {
        let vm = makeViewModel()
        vm.dismissNotice(.missingProvider)
        #expect(vm.dismissedNotices.contains(.missingProvider))
        // And the notice disappears from the visible list.
        #expect(vm.trayNotices.isEmpty)
    }

    @Test("dismissing the last notice collapses the drawer")
    func dismissingLastNoticeCollapsesDrawer() {
        let vm = makeViewModel()
        // User had expanded the drawer to inspect the (single) notice.
        vm.trayExpanded = true
        vm.dismissNotice(.missingProvider)
        // Without the reset, the next inbound notice would render
        // already-expanded — surprising the user with a side panel-style
        // reveal instead of the intended drawer animation.
        #expect(vm.trayExpanded == false)
        #expect(vm.trayNotices.isEmpty)
    }

    @Test("notchTraySize collapses to zero after dismissing the only notice")
    func traySizeCollapsesAfterDismissal() {
        let vm = makeViewModel()
        // Pretend the layout pass has measured a non-trivial drawer height —
        // we want to prove the size reads from `trayNotices.count`, not from
        // a stale measurement.
        vm.trayContentHeight = 120
        #expect(vm.notchTraySize.height > 0)

        vm.dismissNotice(.missingProvider)
        #expect(vm.notchTraySize.height == 0)
    }
}
