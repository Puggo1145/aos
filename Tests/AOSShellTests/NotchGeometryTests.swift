import Testing
import Foundation
import CoreGraphics
@testable import AOSShell

// MARK: - NotchGeometryTests
//
// Pure geometry math from NotchViewModel — no NSWindow / NSScreen access.
// Synthetic screen frame and device-notch rect drive the static helpers.

@Suite("Notch geometry derivations")
struct NotchGeometryTests {

    /// Synthetic 1440×900 retina-ish display with a 200×32 notch.
    private let screenRect = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let deviceNotchRect = CGRect(x: 620, y: 868, width: 200, height: 32)
    private let panel = CGSize(width: 720, height: 240)

    @Test("notchOpenedRect is centred horizontally on the screen")
    func openedRectIsCentred() {
        let rect = NotchViewModel.makeNotchOpenedRect(screenRect: screenRect, panel: panel)
        #expect(rect.midX == screenRect.midX)
        #expect(rect.width == panel.width)
        #expect(rect.height == panel.height)
        // Top-aligned: panel hangs from screenRect.maxY downward.
        #expect(rect.maxY == screenRect.maxY)
        #expect(rect.minY == screenRect.maxY - panel.height)
    }

    @Test("headlineOpenedRect aligns with device notch height")
    func headlineRectMatchesDeviceNotch() {
        let rect = NotchViewModel.makeHeadlineOpenedRect(
            screenRect: screenRect,
            panel: panel,
            deviceNotchHeight: deviceNotchRect.height
        )
        #expect(rect.height == deviceNotchRect.height)
        #expect(rect.width == panel.width)
        #expect(rect.maxY == screenRect.maxY)
    }

    @Test("closedBarRect spans device notch + two h×h satellite squares")
    func closedBarSpansSatellites() {
        let rect = NotchViewModel.makeClosedBarRect(deviceNotchRect: deviceNotchRect)
        #expect(rect.height == deviceNotchRect.height)
        #expect(rect.width == deviceNotchRect.width + deviceNotchRect.height * 2)
        #expect(rect.minX == deviceNotchRect.minX - deviceNotchRect.height)
        #expect(rect.midX == deviceNotchRect.midX)
    }

    @Test("device notch rect uses the system-reported auxiliary gap")
    func deviceNotchRectUsesAuxiliaryGap() {
        let rect = NotchWindowController.makeDeviceNotchRect(
            screenFrame: screenRect,
            notchHeight: 32,
            auxiliaryTopLeftWidth: 663,
            auxiliaryTopRightWidth: 664
        )
        #expect(rect.minX == 663)
        #expect(rect.maxX == 776)
        #expect(rect.midX == 719.5)
        #expect(rect.minY == 868)
    }

    @Test("notch center is converted into top strip local coordinates")
    func notchCenterUsesTopStripLocalCoordinates() {
        let offsetScreen = CGRect(x: -1512, y: 0, width: 1512, height: 982)
        let deviceNotch = CGRect(x: -849, y: 950, width: 185, height: 32)

        let center = NotchWindowController.makeNotchCenterXInWindow(
            screenFrame: offsetScreen,
            deviceNotchRect: deviceNotch
        )

        #expect(center == deviceNotch.midX - offsetScreen.minX)
    }

    @Test("openedRect width matches panel even on narrow screens")
    func openedRectIgnoresScreenWidth() {
        let narrow = CGRect(x: 0, y: 0, width: 800, height: 600)
        let rect = NotchViewModel.makeNotchOpenedRect(screenRect: narrow, panel: panel)
        #expect(rect.width == panel.width)
        #expect(rect.midX == narrow.midX)
    }
}
