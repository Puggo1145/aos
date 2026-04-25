import Foundation
import AppKit
import SwiftUI
import Combine
import AOSOSSenseKit

// MARK: - NotchViewModel
//
// Owns the Notch UI state machine + derived geometry per docs/designs/notch-ui.md.
//
// Holds (read-only) references to `SenseStore` and `AgentService` so the
// SwiftUI views can read context + agent state through one entry point.
// All mutation flows through @MainActor methods.

@MainActor
@Observable
public final class NotchViewModel {
    public enum Status: Sendable, Equatable {
        case closed
        case popping
        case opened
    }

    public enum OpenReason: Sendable, Equatable {
        case click
        case boot
        case unknown
    }

    // MARK: - Stored state

    public private(set) var status: Status = .closed
    public var openReason: OpenReason = .unknown
    public var screenRect: CGRect
    public var deviceNotchRect: CGRect
    public var inputFocused: Bool = false

    // MARK: - Constants

    public let notchOpenedSize = CGSize(width: 500, height: 240)
    public let inset: CGFloat
    public let animation: Animation = .interactiveSpring(
        duration: 0.5,
        extraBounce: 0.25,
        blendDuration: 0.125
    )

    // MARK: - Dependencies (read-only from view)

    public let senseStore: SenseStore
    public let agentService: AgentService

    // Combine cancellables for the event-bridge subscriptions registered in
    // NotchViewModel+Events.swift.
    var cancellables: Set<AnyCancellable> = []

    /// Used to throttle haptic taps on popping transitions.
    var hapticSender = PassthroughSubject<Void, Never>()

    public init(
        senseStore: SenseStore,
        agentService: AgentService,
        screenRect: CGRect,
        deviceNotchRect: CGRect
    ) {
        self.senseStore = senseStore
        self.agentService = agentService
        self.screenRect = screenRect
        self.deviceNotchRect = deviceNotchRect
        // Per design: -4 if there is a real notch, 0 otherwise — expands the
        // hot rect slightly to absorb edge tracking error.
        self.inset = deviceNotchRect.height > 0 ? -4 : 0
    }

    // MARK: - Derived geometry (pure functions)
    //
    // `Notch geometry helpers` are pure and tested independently; see
    // NotchGeometryTests.

    public var notchOpenedRect: CGRect {
        Self.makeNotchOpenedRect(screenRect: screenRect, panel: notchOpenedSize)
    }

    public var headlineOpenedRect: CGRect {
        Self.makeHeadlineOpenedRect(
            screenRect: screenRect,
            panel: notchOpenedSize,
            deviceNotchHeight: deviceNotchRect.height
        )
    }

    public var closedBarRect: CGRect {
        Self.makeClosedBarRect(deviceNotchRect: deviceNotchRect)
    }

    /// Mouse hot zone for closed/popping interactions. From the user's
    /// point of view the entire visible silhouette (icon + physical notch +
    /// emoji) reads as one "fat notch", so any hover/click landing on the
    /// satellite squares should drive popping/opening just like a hit on
    /// the physical cutout. `inset` matches the device-notch slack so edge
    /// tracking stays forgiving.
    public var closedHotRect: CGRect {
        closedBarRect.insetBy(dx: inset, dy: inset)
    }

    /// Screen-space rect of the currently-visible notch silhouette. Drives
    /// `NSWindow.ignoresMouseEvents` in `NotchWindowController` so clicks
    /// outside this rect pass through to the underlying app at the OS level
    /// — `NSHostingView`'s hit-testing returns self for any point in its
    /// bounds even where no SwiftUI view paints, so view-level filtering
    /// (NotchDrop-style or `hitTest`-override style) cannot achieve real
    /// click-through on macOS.
    public var visibleHotRect: CGRect {
        switch status {
        case .opened: return notchOpenedRect
        case .closed, .popping: return closedBarRect
        }
    }

    public nonisolated static func makeNotchOpenedRect(screenRect: CGRect, panel: CGSize) -> CGRect {
        CGRect(
            x: screenRect.midX - panel.width / 2,
            y: screenRect.maxY - panel.height,
            width: panel.width,
            height: panel.height
        )
    }

    public nonisolated static func makeHeadlineOpenedRect(
        screenRect: CGRect,
        panel: CGSize,
        deviceNotchHeight: CGFloat
    ) -> CGRect {
        CGRect(
            x: screenRect.midX - panel.width / 2,
            y: screenRect.maxY - deviceNotchHeight,
            width: panel.width,
            height: deviceNotchHeight
        )
    }

    public nonisolated static func makeClosedBarRect(deviceNotchRect: CGRect) -> CGRect {
        CGRect(
            x: deviceNotchRect.minX - deviceNotchRect.height,
            y: deviceNotchRect.minY,
            width: deviceNotchRect.width + deviceNotchRect.height * 2,
            height: deviceNotchRect.height
        )
    }

    // MARK: - State mutators

    public func notchOpen(_ reason: OpenReason) {
        openReason = reason
        status = .opened
        NSApp.activate(ignoringOtherApps: true)
        broadcastStatus()
    }

    public func notchClose() {
        status = .closed
        broadcastStatus()
    }

    public func notchPop() {
        guard status == .closed else { return }
        status = .popping
        broadcastStatus()
    }

    /// Cancel all subscriptions; called by the controller during destroy.
    public func destroy() {
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
    }
}
