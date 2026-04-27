import Foundation

/// AOS Shell ↔ Bun Sidecar JSON-RPC protocol version.
///
/// Bumped per docs/designs/rpc-protocol.md §"版本协商":
/// - MAJOR mismatch ⇒ Shell rejects handshake and terminates Bun
/// - MINOR / PATCH mismatch ⇒ logged as warning, accepted
public let aosProtocolVersion: String = "2.0.0"
