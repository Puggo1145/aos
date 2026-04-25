// AOS Shell ↔ Bun Sidecar JSON-RPC schema (TypeScript side).
//
// This file is hand-maintained to mirror `Sources/AOSRPCSchema/*.swift` field
// for field. Source of truth is the Swift Codable types per
// docs/designs/rpc-protocol.md §"Schema 单一信源". Drift is caught by the
// `tests/rpc-fixtures/*.json` byte-equal conformance tests on both sides.

// ---------------------------------------------------------------------------
// Protocol version
// ---------------------------------------------------------------------------

/// Bumped per docs/designs/rpc-protocol.md §"版本协商":
/// MAJOR mismatch ⇒ Shell rejects handshake; MINOR/PATCH ⇒ warn + accept.
export const AOS_PROTOCOL_VERSION = "1.0.0" as const;

// ---------------------------------------------------------------------------
// JSON-RPC envelopes
// ---------------------------------------------------------------------------

export type RPCId = number | string;

export interface RPCRequest<P> {
  jsonrpc: "2.0";
  id: RPCId;
  method: string;
  params: P;
}

export interface RPCResponse<R> {
  jsonrpc: "2.0";
  id: RPCId;
  result: R;
}

export interface RPCErrorResponse {
  jsonrpc: "2.0";
  id: RPCId;
  error: RPCError;
}

export interface RPCNotification<P> {
  jsonrpc: "2.0";
  method: string;
  params: P;
}

// ---------------------------------------------------------------------------
// Error model — per docs/designs/rpc-protocol.md §"错误模型"
// ---------------------------------------------------------------------------

export interface RPCError {
  code: number;
  message: string;
  data?: JSONValue;
}

export const RPCErrorCode = {
  // Standard JSON-RPC
  parseError: -32700,
  invalidRequest: -32600,
  methodNotFound: -32601,
  invalidParams: -32602,
  internalError: -32603,
  // AOS application generic segment
  unhandshaked: -32000,
  payloadTooLarge: -32001,
  timeout: -32002,
  permissionDenied: -32003,
} as const;

export type RPCErrorCodeName = keyof typeof RPCErrorCode;

// ---------------------------------------------------------------------------
// JSON value (recursive)
// ---------------------------------------------------------------------------

export type JSONValue =
  | null
  | boolean
  | number
  | string
  | JSONValue[]
  | { [k: string]: JSONValue };

// ---------------------------------------------------------------------------
// Method name constants
// ---------------------------------------------------------------------------

export const RPCMethod = {
  rpcHello: "rpc.hello",
  rpcPing: "rpc.ping",
  agentSubmit: "agent.submit",
  agentCancel: "agent.cancel",
  uiToken: "ui.token",
  uiStatus: "ui.status",
  uiError: "ui.error",
} as const;

// ---------------------------------------------------------------------------
// rpc.hello / rpc.ping
// ---------------------------------------------------------------------------

export interface ClientInfo {
  name: string;
  version: string;
}

export interface ServerInfo {
  name: string;
  version: string;
}

export interface HelloParams {
  protocolVersion: string;
  clientInfo: ClientInfo;
}

export interface HelloResult {
  protocolVersion: string;
  serverInfo: ServerInfo;
}

/// `rpc.ping` is a payload-less request: params and result both serialize as `{}`.
export type PingParams = Record<string, never>;
export type PingResult = Record<string, never>;

// ---------------------------------------------------------------------------
// agent.* — Shell → Bun
// ---------------------------------------------------------------------------

export interface AgentSubmitParams {
  turnId: string;
  prompt: string;
  citedContext: CitedContext;
}

export interface AgentSubmitResult {
  accepted: boolean;
}

export interface AgentCancelParams {
  turnId: string;
}

export interface AgentCancelResult {
  cancelled: boolean;
}

// ---------------------------------------------------------------------------
// CitedContext — wire-only projection of Shell's SenseContext
// ---------------------------------------------------------------------------

export interface CitedContext {
  app?: CitedApp;
  window?: CitedWindow;
  behaviors?: BehaviorEnvelope[];
  visual?: CitedVisual;
  clipboard?: CitedClipboard;
}

export interface CitedApp {
  bundleId: string;
  name: string;
  pid: number;
  /// Base64-encoded PNG. Optional.
  iconPNG?: string;
}

export interface CitedWindow {
  title: string;
  /// CGWindowID hint. May be stale; re-resolve via computerUse.listWindows.
  windowId?: number;
}

export interface BehaviorEnvelope {
  kind: string;
  citationKey: string;
  displaySummary: string;
  /// Opaque per-producer JSON; sidecar passes through unchanged.
  payload: JSONValue;
}

export interface CitedVisualSize {
  width: number;
  height: number;
}

export interface CitedVisual {
  /// Base64-encoded PNG, ≤ 400KB after encoding.
  frame: string;
  frameSize: CitedVisualSize;
  /// ISO-8601 UTC timestamp.
  capturedAt: string;
}

// CitedClipboard — discriminated union, mirrors Swift's Codable encoding.
export type CitedClipboard =
  | { kind: "text"; content: string }
  | { kind: "filePaths"; paths: string[] }
  | { kind: "image"; metadata: CitedClipboardImageMetadata };

export interface CitedClipboardImageMetadata {
  width: number;
  height: number;
  type: string;
}

// ---------------------------------------------------------------------------
// ui.* — Bun → Shell notifications
// ---------------------------------------------------------------------------

export interface UITokenParams {
  turnId: string;
  delta: string;
}

export type UIStatus = "thinking" | "tool_calling" | "waiting_input" | "done";

export interface UIStatusParams {
  turnId: string;
  status: UIStatus;
}

export interface UIErrorParams {
  turnId: string;
  code: number;
  message: string;
  data?: JSONValue;
}
