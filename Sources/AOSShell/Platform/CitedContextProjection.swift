import Foundation
import AppKit
import AOSRPCSchema
import AOSOSSenseKit

// MARK: - SenseContext → CitedContext projection
//
// Lives at the Shell composition seam per docs/designs/os-sense.md §"依赖
// 方向（核心契约）" — OS Sense never imports the wire schema; the Shell is
// the place that translates between the live model (NSImage / CGImage etc.)
// and the wire schema (base64 PNG, structured strings).
//
// Stage 0 scope: only `app` and `window` are projected. `behaviors`,
// `visual`, `clipboard` are always omitted because no producer exists yet
// (degraded path explicitly defined by the design, not a placeholder).

enum CitedContextProjection {
    /// Maximum size for the encoded icon PNG, per rpc-protocol.md §"二进制
    /// payload 规则" (`citedContext.visual.frame` is 400KB; the icon shares
    /// that ceiling so a single CitedContext stays well below 2MB).
    static let maxIconPNGBytes = 400 * 1024

    static func project(from sense: SenseContext) -> CitedContext {
        let app = sense.app.flatMap { project(app: $0) }
        let window = sense.window.map { project(window: $0) }
        return CitedContext(
            app: app,
            window: window,
            behaviors: nil,    // Stage 0: empty list omitted from wire entirely
            visual: nil,
            clipboard: nil
        )
    }

    private static func project(app: AppIdentity) -> CitedApp {
        let iconPNG = app.icon.flatMap { encodeIcon($0) }
        return CitedApp(
            bundleId: app.bundleId,
            name: app.name,
            pid: Int(app.pid),
            iconPNG: iconPNG
        )
    }

    private static func project(window: WindowIdentity) -> CitedWindow {
        CitedWindow(
            title: window.title,
            windowId: window.windowId.map { Int($0) }
        )
    }

    /// Encode an NSImage to base64 PNG, downsampling progressively if the
    /// resulting payload would exceed `maxIconPNGBytes`. Apple icons are
    /// typically 1024×1024 — usually one downsample to 256 is enough.
    private static func encodeIcon(_ image: NSImage) -> String? {
        let candidates: [CGFloat] = [1.0, 0.5, 0.25, 0.125]
        for scale in candidates {
            guard let data = pngData(image, scale: scale) else { continue }
            // base64 encoded length ≈ 4/3 * data.count.
            if data.count * 4 / 3 <= maxIconPNGBytes {
                return data.base64EncodedString()
            }
        }
        return nil
    }

    private static func pngData(_ image: NSImage, scale: CGFloat) -> Data? {
        let targetSize = CGSize(
            width: image.size.width * scale,
            height: image.size.height * scale
        )
        guard targetSize.width >= 16, targetSize.height >= 16 else { return nil }
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(targetSize.width),
            pixelsHigh: Int(targetSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        guard let rep else { return nil }
        rep.size = targetSize
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = ctx
        image.draw(
            in: NSRect(origin: .zero, size: targetSize),
            from: .zero,
            operation: .copy,
            fraction: 1.0
        )
        return rep.representation(using: .png, properties: [:])
    }
}
