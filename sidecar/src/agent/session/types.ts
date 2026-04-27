// Session-layer types.
//
// Per docs/designs/session-management.md. Only types that need to be shared
// across session/{session,manager,handlers}.ts and the loop live here. Wire
// schema is owned by `rpc/rpc-types.ts`; this file mirrors the runtime shape.

export type SessionId = string;

export interface SessionInfo {
  /// Process-unique. `sess_<8-byte hex>`.
  id: SessionId;
  /// ms since epoch.
  createdAt: number;
  /// Default "新对话"; auto-derived from first user prompt (≤32 chars, first
  /// non-empty line). Derivation runs once on first submit; not auto-overwritten.
  title: string;
}

/// Wire-shape view of a session for `session.list` / `session.created`.
/// `turnCount` and `lastActivityAt` are derived on demand from the session's
/// Conversation — no caching to avoid drift.
export interface SessionListItem {
  id: SessionId;
  title: string;
  createdAt: number;
  /// Only `status === "done"` turns count. In-flight / error / cancelled excluded.
  turnCount: number;
  /// Last turn's `startedAt`; equals `createdAt` for empty sessions.
  lastActivityAt: number;
}

/// Manager → sink events. Wire mapping (Step 2):
///   created      → session.created     { session: SessionListItem }
///   activated    → session.activated   { sessionId }
///   listChanged  → session.listChanged {}
export type SessionEvent =
  | { kind: "created"; session: SessionListItem }
  | { kind: "activated"; sessionId: SessionId }
  | { kind: "listChanged" };
