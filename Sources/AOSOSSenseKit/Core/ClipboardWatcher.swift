import Foundation
import AppKit

// MARK: - ClipboardWatcher
//
// Per `docs/designs/os-sense.md` §"ClipboardWatcher":
//   - 1 Hz `NSPasteboard.changeCount` poll
//   - cross-check on `NSWorkspace.didActivateApplicationNotification` so
//     stale clipboard never sticks past a manual paste-target switch
//   - type priority: public.file-url > public.utf8-plain-text > public.image
//   - images are reported by metadata only (width/height/type), never pixels
//   - text > 2KB is truncated using the same rule as GeneralProbe
//
// Independent of the frontmost app — clipboard is global to the user
// session, not the foreground app.

@MainActor
public final class ClipboardWatcher {
    public static let textTruncationLimit: Int = GeneralProbe.textTruncationLimit
    private static let pollInterval: TimeInterval = 1.0

    private let pasteboard: NSPasteboard
    private let onChange: @MainActor (ClipboardItem?) -> Void

    private var lastChangeCount: Int = -1
    private var timer: Timer?
    private var activationObserver: NSObjectProtocol?

    public init(
        pasteboard: NSPasteboard = .general,
        onChange: @escaping @MainActor (ClipboardItem?) -> Void
    ) {
        self.pasteboard = pasteboard
        self.onChange = onChange
    }

    public func start() {
        // Seed `lastChangeCount` to the current clipboard generation so we
        // don't spuriously re-emit the same item at startup. Then immediately
        // surface the current item once so the chip row reflects what's on
        // the user's clipboard before the first change.
        lastChangeCount = pasteboard.changeCount
        onChange(extractItem())

        timer = Timer.scheduledTimer(
            withTimeInterval: Self.pollInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }

        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        if let observer = activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        activationObserver = nil
    }

    /// Test seam: trigger a single check without waiting for the timer or an
    /// app activation event. Internal so `@testable import` reaches it.
    internal func _tickForTesting() {
        tick()
    }

    private func tick() {
        let current = pasteboard.changeCount
        if current == lastChangeCount { return }
        lastChangeCount = current
        onChange(extractItem())
    }

    /// Project the current pasteboard contents into a `ClipboardItem` per
    /// the design's type priority. Returns nil for clipboards we can't
    /// represent (empty, or only types we don't surface).
    private func extractItem() -> ClipboardItem? {
        // 1. file-url → list of paths. `readObjects` for NSURL covers both
        //    public.file-url + drag-from-Finder pasteboard styles.
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            return .filePaths(urls)
        }

        // 2. utf8-plain-text → text, truncated to 2KB.
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            return .text(GeneralProbe.truncate(text))
        }

        // 3. image → metadata only. Use TIFF/PNG metadata via NSImage to get
        //    the size; never read the pixel buffer into our envelope.
        if let images = pasteboard.readObjects(
            forClasses: [NSImage.self],
            options: nil
        ) as? [NSImage], let image = images.first {
            return Self.projectImage(image, pasteboard: pasteboard)
        }

        return nil
    }

    /// Pure projection of an `NSImage` clipboard entry into image metadata.
    /// `pasteboard` is consulted only to detect the source UTI (PNG / TIFF
    /// / JPEG) — pixel data never leaves this function.
    internal static func projectImage(
        _ image: NSImage,
        pasteboard: NSPasteboard
    ) -> ClipboardItem? {
        let pixelSize = pixelSize(of: image)
        guard pixelSize.width > 0, pixelSize.height > 0 else { return nil }
        let type = imageType(pasteboard: pasteboard)
        return .image(metadata: ImageMetadata(
            width: Int(pixelSize.width),
            height: Int(pixelSize.height),
            type: type
        ))
    }

    private static func pixelSize(of image: NSImage) -> CGSize {
        // `NSImage.size` is in points; for pasted bitmaps we want pixels so
        // a Retina screenshot reports 2880×1800 instead of 1440×900.
        if let rep = image.representations.first as? NSBitmapImageRep {
            return CGSize(width: CGFloat(rep.pixelsWide), height: CGFloat(rep.pixelsHigh))
        }
        return image.size
    }

    private static func imageType(pasteboard: NSPasteboard) -> String {
        let priorities: [NSPasteboard.PasteboardType] = [.png, .tiff]
        for type in priorities {
            if pasteboard.availableType(from: [type]) != nil {
                return type.rawValue
            }
        }
        // Fallback: report whatever image-ish type is first available so the
        // LLM knows there's an image even on uncommon clipboards.
        if let any = pasteboard.types?.first(where: {
            $0.rawValue.contains("image") || $0.rawValue.contains("png") || $0.rawValue.contains("tiff")
        }) {
            return any.rawValue
        }
        return "public.image"
    }
}
