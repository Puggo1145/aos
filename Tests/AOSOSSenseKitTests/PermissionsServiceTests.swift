import Testing
import Foundation
@testable import AOSOSSenseKit

@Suite("PermissionsService — denied set projection")
struct PermissionsServiceTests {

    @Test("All granted → empty denied set")
    func allGranted() {
        let denied = PermissionsService.computeDeniedSet(
            axTrusted: true,
            screenRecordingGranted: true
        )
        #expect(denied.isEmpty)
    }

    @Test("Accessibility denied only")
    func accessibilityDeniedOnly() {
        let denied = PermissionsService.computeDeniedSet(
            axTrusted: false,
            screenRecordingGranted: true
        )
        #expect(denied == [.accessibility])
    }

    @Test("Screen recording denied only")
    func screenRecordingDeniedOnly() {
        let denied = PermissionsService.computeDeniedSet(
            axTrusted: true,
            screenRecordingGranted: false
        )
        #expect(denied == [.screenRecording])
    }

    @Test("Both denied")
    func bothDenied() {
        let denied = PermissionsService.computeDeniedSet(
            axTrusted: false,
            screenRecordingGranted: false
        )
        #expect(denied == [.accessibility, .screenRecording])
    }

    @Test("Automation is never reported by Stage 0 (no probe)")
    func automationNeverReported() {
        for ax in [true, false] {
            for sr in [true, false] {
                let denied = PermissionsService.computeDeniedSet(
                    axTrusted: ax,
                    screenRecordingGranted: sr
                )
                #expect(!denied.contains(.automation))
            }
        }
    }

    @MainActor
    @Test("Default state is empty until refresh()")
    func defaultStateEmpty() {
        let svc = PermissionsService()
        #expect(svc.state.denied.isEmpty)
    }
}
