import Foundation
import ApplicationServices

// MARK: - AOSAXSupport
//
// Shared low-level Accessibility SPI bridge per
// `docs/designs/os-sense.md` §"共享 AX SPI 底层模块":
//
//   "_AXUIElementGetWindow 等 macOS 私有 AX SPI 的 @_silgen_name 桥接归
//    属于独立的 AOSAXSupport Swift package，OS Sense Core 与
//    AOSComputerUseKit 都依赖它。"
//
// Putting these declarations in their own package is what enforces the
// "read side does not depend on write side" rule: AOSOSSenseKit and the
// future AOSComputerUseKit each depend on AOSAXSupport, and not on each
// other.
//
// `_AXUIElementGetWindow(_:_:)` is an unpublished Apple SPI that returns
// the CGWindowID associated with an `AXUIElement`. The function exists on
// every macOS version we target, but is not declared in the public AX
// headers. We pull it in via `@_silgen_name` so the linker resolves it
// directly out of the AppKit framework binary.

/// Apple-private SPI: get the `CGWindowID` for an `AXUIElement`. Returns an
/// `AXError`. `windowId` is left untouched on failure, so callers must
/// initialize it before passing.
///
/// Available on every macOS version we target; absence would be a system
/// integrity issue, not an OS-version concern.
@_silgen_name("_AXUIElementGetWindow")
public func _AXUIElementGetWindow(
    _ element: AXUIElement,
    _ windowId: UnsafeMutablePointer<CGWindowID>
) -> AXError

/// Convenience wrapper. Returns nil iff the SPI returned a non-success
/// AXError — typically: the element is no longer alive, or it doesn't
/// represent a window. The Swifty form is what callers should use; the raw
/// `@_silgen_name` declaration above is exposed only for advanced cases
/// (and to keep the bridge declaration in the same file for maintenance).
public func axWindowID(for element: AXUIElement) -> CGWindowID? {
    var windowId: CGWindowID = 0
    let err = _AXUIElementGetWindow(element, &windowId)
    return err == .success ? windowId : nil
}
