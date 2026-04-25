import Foundation

// MARK: - agent.* params / results
//
// Per docs/designs/rpc-protocol.md §"agent.*（Shell → Bun）".
// `agent.submit` carries the prompt plus the **wire-only** `CitedContext`
// projection of `SenseContext`. `agent.cancel` is keyed by `turnId`.

public struct AgentSubmitParams: Codable, Sendable, Equatable {
    public let turnId: String
    public let prompt: String
    public let citedContext: CitedContext

    public init(turnId: String, prompt: String, citedContext: CitedContext) {
        self.turnId = turnId
        self.prompt = prompt
        self.citedContext = citedContext
    }
}

public struct AgentSubmitResult: Codable, Sendable, Equatable {
    public let accepted: Bool

    public init(accepted: Bool) {
        self.accepted = accepted
    }
}

public struct AgentCancelParams: Codable, Sendable, Equatable {
    public let turnId: String

    public init(turnId: String) {
        self.turnId = turnId
    }
}

public struct AgentCancelResult: Codable, Sendable, Equatable {
    public let cancelled: Bool

    public init(cancelled: Bool) {
        self.cancelled = cancelled
    }
}

// MARK: - CitedContext
//
// Wire-only projection of `SenseContext`. Live model fields that hold
// non-serializable types (NSImage, CGImage, …) are flattened or dropped.
// All inner fields are optional — degraded mode (no AX, no adapters)
// serializes as `{}`. Per design doc, this is graceful degradation,
// not a stub: missing fields are omitted, never serialized as `null`.

public struct CitedContext: Codable, Sendable, Equatable {
    public let app: CitedApp?
    public let window: CitedWindow?
    public let behaviors: [BehaviorEnvelope]?
    public let visual: CitedVisual?
    public let clipboard: CitedClipboard?

    public init(
        app: CitedApp? = nil,
        window: CitedWindow? = nil,
        behaviors: [BehaviorEnvelope]? = nil,
        visual: CitedVisual? = nil,
        clipboard: CitedClipboard? = nil
    ) {
        self.app = app
        self.window = window
        self.behaviors = behaviors
        self.visual = visual
        self.clipboard = clipboard
    }
}

public struct CitedApp: Codable, Sendable, Equatable {
    public let bundleId: String
    public let name: String
    public let pid: Int
    /// Base64-encoded PNG of the app icon. Optional; omitted when
    /// `NSRunningApplication.icon` is unavailable.
    public let iconPNG: String?

    public init(bundleId: String, name: String, pid: Int, iconPNG: String? = nil) {
        self.bundleId = bundleId
        self.name = name
        self.pid = pid
        self.iconPNG = iconPNG
    }
}

public struct CitedWindow: Codable, Sendable, Equatable {
    public let title: String
    /// `CGWindowID`. Hint, not a long-lived handle. Per design, callers must
    /// re-resolve via `computerUse.listWindows({pid})` if the window has
    /// been recreated, moved between Spaces, etc.
    public let windowId: Int?

    public init(title: String, windowId: Int? = nil) {
        self.title = title
        self.windowId = windowId
    }
}

public struct BehaviorEnvelope: Codable, Sendable, Equatable {
    public let kind: String
    public let citationKey: String
    public let displaySummary: String
    /// Opaque per-producer JSON. Sidecar passes through unchanged.
    public let payload: JSONValue

    public init(
        kind: String,
        citationKey: String,
        displaySummary: String,
        payload: JSONValue
    ) {
        self.kind = kind
        self.citationKey = citationKey
        self.displaySummary = displaySummary
        self.payload = payload
    }
}

public struct CitedVisualSize: Codable, Sendable, Equatable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public struct CitedVisual: Codable, Sendable, Equatable {
    /// Base64-encoded PNG, ≤ 400KB after encoding.
    public let frame: String
    public let frameSize: CitedVisualSize
    /// ISO-8601 UTC timestamp.
    public let capturedAt: String

    public init(frame: String, frameSize: CitedVisualSize, capturedAt: String) {
        self.frame = frame
        self.frameSize = frameSize
        self.capturedAt = capturedAt
    }
}

// MARK: - CitedClipboard
//
// Discriminated union, encoded as `{ kind: "...", ... }`:
//   - `.text(String)`         → `{ kind: "text", content }`
//   - `.filePaths([String])`  → `{ kind: "filePaths", paths }`
//   - `.image(metadata: …)`   → `{ kind: "image", metadata: { width, height, type } }`

public struct CitedClipboardImageMetadata: Codable, Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let type: String

    public init(width: Int, height: Int, type: String) {
        self.width = width
        self.height = height
        self.type = type
    }
}

public enum CitedClipboard: Sendable, Equatable, Codable {
    case text(String)
    case filePaths([String])
    case image(metadata: CitedClipboardImageMetadata)

    private enum CodingKeys: String, CodingKey {
        case kind
        case content
        case paths
        case metadata
    }

    private enum Kind: String {
        case text
        case filePaths
        case image
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kindRaw = try container.decode(String.self, forKey: .kind)
        guard let kind = Kind(rawValue: kindRaw) else {
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Unknown CitedClipboard kind: \(kindRaw)"
            )
        }
        switch kind {
        case .text:
            let s = try container.decode(String.self, forKey: .content)
            self = .text(s)
        case .filePaths:
            let p = try container.decode([String].self, forKey: .paths)
            self = .filePaths(p)
        case .image:
            let m = try container.decode(CitedClipboardImageMetadata.self, forKey: .metadata)
            self = .image(metadata: m)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let s):
            try container.encode(Kind.text.rawValue, forKey: .kind)
            try container.encode(s, forKey: .content)
        case .filePaths(let p):
            try container.encode(Kind.filePaths.rawValue, forKey: .kind)
            try container.encode(p, forKey: .paths)
        case .image(let m):
            try container.encode(Kind.image.rawValue, forKey: .kind)
            try container.encode(m, forKey: .metadata)
        }
    }
}
