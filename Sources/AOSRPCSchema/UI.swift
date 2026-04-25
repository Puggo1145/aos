import Foundation

// MARK: - ui.* notification params
//
// Per docs/designs/rpc-protocol.md §"ui.*（Bun → Shell）". All `ui.*` methods
// are notifications keyed by `turnId`, driving streaming state in the Notch UI.

public struct UITokenParams: Codable, Sendable, Equatable {
    public let turnId: String
    public let delta: String

    public init(turnId: String, delta: String) {
        self.turnId = turnId
        self.delta = delta
    }
}

/// Discrete agent status pushed by the sidecar agent loop.
public enum UIStatus: String, Codable, Sendable, Equatable, CaseIterable {
    case thinking
    case toolCalling = "tool_calling"
    case waitingInput = "waiting_input"
    case done
}

public struct UIStatusParams: Codable, Sendable, Equatable {
    public let turnId: String
    public let status: UIStatus

    public init(turnId: String, status: UIStatus) {
        self.turnId = turnId
        self.status = status
    }
}

public struct UIErrorParams: Codable, Sendable, Equatable {
    public let turnId: String
    public let code: Int
    public let message: String
    public let data: JSONValue?

    public init(turnId: String, code: Int, message: String, data: JSONValue? = nil) {
        self.turnId = turnId
        self.code = code
        self.message = message
        self.data = data
    }
}
