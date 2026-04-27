// Agent turn loop — bridges `agent.submit` / `agent.cancel` / `agent.reset`
// to the sidecar's `Conversation` store and the `llm/` stream.
//
// Per docs/designs/rpc-protocol.md §"流式语义":
//   1. agent.submit Request returns { accepted: true } immediately. The actual
//      LLM streaming happens in a detached background task. *Before* the ack
//      we register the turn into the Conversation and broadcast
//      `conversation.turnStarted` so observers see the turn appear before any
//      streamed token.
//   2. While streaming, ui.token / ui.status / ui.error notifications are
//      pushed AND the matching turn in the Conversation is mutated in place.
//      This dual write is intentional: ui.token is the cheap streaming
//      transport (no full snapshot per character); the Conversation is the
//      durable store that drives the next request's LLM context.
//   3. agent.cancel triggers the per-turn AbortController; the stream loop
//      observes `signal.aborted`, breaks out, and emits `ui.status done`.
//   4. agent.reset aborts every live stream, wipes the Conversation, and
//      emits `conversation.reset` so observers can drop their mirrors.
//
// Per docs/designs/llm-provider.md §"包边界" the loop only depends on the
// public surface re-exported from `../llm`.

import { streamSimple, getDefaultModel, getModel, isContextOverflow, PROVIDER_IDS, effectiveEffort, type AssistantMessage, type Model, type Api } from "../llm";
import { readUserConfig } from "../config/storage";
import {
  RPCErrorCode,
  RPCMethod,
  type AgentSubmitParams,
  type AgentSubmitResult,
  type AgentCancelParams,
  type AgentCancelResult,
  type AgentResetResult,
} from "../rpc/rpc-types";
import { Dispatcher, RPCMethodError } from "../rpc/dispatcher";
import { TurnRegistry } from "./registry";
import { Conversation } from "./conversation";
import { contextObserver as defaultContextObserver, ContextObserver } from "./context-observer";
import { SessionManager } from "./session/manager";
import { logger } from "../log";

const SYSTEM_PROMPT = "You are AOS, an AI agent embedded in macOS via the notch UI. Be concise and helpful.";

// ---------------------------------------------------------------------------
// Test injection point.
//
// Tests substitute the model resolver so a fake model + fake stream provider
// can be wired in without touching the global model / api registries. The
// production resolver reads the user's saved selection from the global config
// (set via the Shell settings panel → `config.set`); on a missing or stale
// selection it falls back to the catalog's `DEFAULT_MODEL_PER_PROVIDER`.
// Catalog stays the single source of truth — runtime code does not hardcode
// provider ids or model ids.
// ---------------------------------------------------------------------------

type ModelResolver = () => Model<Api>;

/// Resolve the model the agent loop should drive.
///
/// Per P2.4: stale and malformed config are different. A *missing* selection
/// (user has never picked) silently falls back to the catalog default — that
/// is the documented first-run path. A *stale* selection (saved id no longer
/// in the catalog) throws so `runTurn`'s top-level catch surfaces it as a
/// `ui.error`. Malformed config also throws (raised by `readUserConfig`).
/// Both error paths reach the user instead of silently swapping their model.
const defaultResolver: ModelResolver = () => {
  const cfg = readUserConfig();
  if (cfg.selection) {
    try {
      return getModel(cfg.selection.providerId, cfg.selection.modelId);
    } catch {
      throw new Error(
        `Configured model "${cfg.selection.providerId}/${cfg.selection.modelId}" is no longer available. ` +
          `Open Settings and pick a model.`,
      );
    }
  }
  return getDefaultModel(PROVIDER_IDS.chatgptPlan);
};
let modelResolver: ModelResolver = defaultResolver;

export function setModelResolver(fn: ModelResolver): void {
  modelResolver = fn;
}

export function resetModelResolver(): void {
  modelResolver = defaultResolver;
}

// ---------------------------------------------------------------------------
// Error code mapping
// ---------------------------------------------------------------------------

/// Per design risk note: ErrPermissionDenied (-32003) covers auth failures
/// (missing/expired ChatGPT token, 401 from upstream). Everything else is
/// surfaced as the generic agent-segment internal error.
///
/// We trust the typed `errorReason` field exclusively. Provider implementations
/// MUST tag auth failures with `errorReason: "authInvalidated"`; relying on
/// regex over `errorMessage` would let provider wording drift silently change
/// the surfaced code. If an auth failure slips through without the typed tag,
/// it will surface as InternalError — the right pressure to make providers
/// emit the typed reason.
export function pickErrorCode(msg: AssistantMessage): number {
  if (msg.errorReason === "authInvalidated") return RPCErrorCode.permissionDenied;
  return RPCErrorCode.internalError;
}

// ---------------------------------------------------------------------------
// Handler registration
// ---------------------------------------------------------------------------

export interface RegisterAgentOptions {
  /// SessionManager owning the per-session Conversation + TurnRegistry pair.
  /// Required. In production, `src/index.ts` constructs a fresh one; tests
  /// inject their own and pre-create as many sessions as needed.
  manager: SessionManager;
  /// Override the context observer used by Dev Mode.
  contextObserver?: ContextObserver;
}

export function registerAgentHandlers(dispatcher: Dispatcher, opts: RegisterAgentOptions): void {
  const observer = opts.contextObserver ?? defaultContextObserver;
  const manager = opts.manager;

  // Wire the observer's sink to the dispatcher. The agent loop only ever
  // calls `observer.publish(...)`; this is the single edge where the
  // dev-mode signal crosses into the wire protocol.
  observer.setSink((snapshot) => {
    dispatcher.notify(RPCMethod.devContextChanged, { snapshot });
  });

  dispatcher.registerRequest(RPCMethod.devContextGet, async () => {
    return { snapshot: observer.latest() };
  });

  /// Resolve a sessionId to its Session, or throw `unknownSession`. Used by
  /// every `agent.*` handler — none of them fall back to `manager.activeId`
  /// per the design's "active session 显式投影到 wire" principle.
  const resolveSession = (sessionId: unknown) => {
    if (typeof sessionId !== "string") {
      throw new RPCMethodError(RPCErrorCode.invalidParams, "missing or non-string sessionId");
    }
    const s = manager.get(sessionId);
    if (!s) {
      throw new RPCMethodError(RPCErrorCode.unknownSession, `unknown sessionId: ${sessionId}`);
    }
    return s;
  };

  dispatcher.registerRequest(RPCMethod.agentSubmit, async (raw): Promise<AgentSubmitResult> => {
    const params = (raw ?? {}) as AgentSubmitParams;
    const { sessionId, turnId, prompt, citedContext } = params;
    if (typeof turnId !== "string" || typeof prompt !== "string" || citedContext === undefined) {
      throw new RPCMethodError(
        RPCErrorCode.invalidParams,
        "agent.submit requires { sessionId, turnId, prompt, citedContext }",
      );
    }
    const session = resolveSession(sessionId);
    const convo = session.conversation;
    const reg = session.turns;

    if (reg.get(turnId)) {
      throw new RPCMethodError(RPCErrorCode.invalidRequest, `turnId already active: ${turnId}`);
    }

    // Register the turn in the Conversation *before* the ack so any
    // observer that subscribes after seeing the ack still finds the turn
    // in the store. The notification is fired here too — it is part of the
    // submit ack contract, not an out-of-band signal.
    const turn = convo.startTurn({ id: turnId, prompt, citedContext });
    dispatcher.notify(RPCMethod.conversationTurnStarted, {
      sessionId: session.id,
      turn: Conversation.toWire(turn),
    });

    // First-prompt title derivation. listChanged covers both the title flip
    // and the lastActivityAt advance from createdAt → turn.startedAt.
    const titleChanged = manager.maybeDeriveTitle(session.id, prompt);
    if (titleChanged || convo.turns.length === 1) {
      manager.notifyListChanged();
    }

    const controller = reg.add(turnId);

    // Detached: ack must return inside agent.submit's 1s budget.
    void runTurn(dispatcher, convo, {
      sessionId: session.id,
      turnId,
      signal: controller.signal,
      observer,
      onDone: () => manager.notifyListChanged(),
    })
      .catch((err) => logger.error("agent loop fatal", { sessionId: session.id, turnId, err: String(err) }))
      .finally(() => reg.remove(turnId));

    return { accepted: true };
  });

  dispatcher.registerRequest(RPCMethod.agentCancel, async (raw): Promise<AgentCancelResult> => {
    const { sessionId, turnId } = (raw ?? {}) as AgentCancelParams;
    if (typeof turnId !== "string") {
      throw new RPCMethodError(RPCErrorCode.invalidParams, "agent.cancel requires { sessionId, turnId }");
    }
    const session = resolveSession(sessionId);
    const cancelled = session.turns.abort(turnId);
    if (cancelled) {
      // Mark the turn cancelled so future `llmMessages()` builds skip it.
      // The boolean return is an `unknown turnId` no-op — only happens if
      // the turn was concurrently reset, which is a tolerated race.
      session.conversation.setStatus(turnId, "cancelled");
    }
    return { cancelled };
  });

  dispatcher.registerRequest(RPCMethod.agentReset, async (raw): Promise<AgentResetResult> => {
    const { sessionId } = (raw ?? {}) as AgentResetParams;
    const session = resolveSession(sessionId);
    session.turns.abortAll();
    session.conversation.reset();
    dispatcher.notify(RPCMethod.conversationReset, { sessionId: session.id });
    // turnCount/lastActivityAt regress; surface to history list.
    manager.notifyListChanged();
    return { ok: true };
  });
}

// ---------------------------------------------------------------------------
// runTurn — exported for tests
// ---------------------------------------------------------------------------

export async function runTurn(
  dispatcher: Dispatcher,
  convo: Conversation,
  params: {
    sessionId: string;
    turnId: string;
    signal: AbortSignal;
    observer?: ContextObserver;
    /// Called when the turn lands in a terminal `done` state (post-`markDone`).
    /// Loop uses this to fire `session.listChanged` (turnCount + lastActivityAt
    /// changed). Errored / cancelled paths do not increment turnCount, so they
    /// don't invoke this hook.
    onDone?: () => void;
  },
): Promise<void> {
  const { sessionId, turnId, signal } = params;
  const observer = params.observer ?? defaultContextObserver;

  dispatcher.notify(RPCMethod.uiStatus, { sessionId, turnId, status: "thinking" });

  let model: Model<Api>;
  let cfg: ReturnType<typeof readUserConfig>;
  try {
    model = modelResolver();
    cfg = readUserConfig();
  } catch (err) {
    // Covers both `modelResolver` failures (missing model, malformed config
    // raised inside its own readUserConfig call) and the bare `readUserConfig`
    // call below. The boolean return signals whether the durable mutation
    // landed; we ALWAYS notify on this top-level boot failure because the
    // turn was just registered and the caller deserves a visible error.
    const message = err instanceof Error ? err.message : String(err);
    logger.error("model/config resolution failed", { turnId, err: String(err) });
    convo.setError(turnId, RPCErrorCode.internalError, message);
    dispatcher.notify(RPCMethod.uiError, {
      sessionId,
      turnId,
      code: RPCErrorCode.internalError,
      message,
    });
    return;
  }

  // Resolve the effort once via the catalog-driven helper. Non-reasoning
  // models return `undefined` (the field is then dropped from the wire
  // payload). Reasoning models get the user's pick clamped onto the
  // model's supported effort list, with the per-model / global default
  // filled in when the user has never chosen. All effort policy lives in
  // `models/effort.ts` — do not branch on `model.reasoning` here.
  const effort: string | undefined = effectiveEffort(model, cfg.effort);

  // Tracks whether a reasoning block has been opened on the wire and not yet
  // closed. The provider stream's `thinking_end` is the happy-path closer,
  // but providers can also bail out of thinking with an error, the user can
  // cancel mid-trace, or an exception can propagate before the provider
  // emits `thinking_end`. In every one of those terminal paths we MUST
  // synthesize a `{ kind: "end" }` before the terminal `ui.error` /
  // `ui.status done`, otherwise the Shell's shimmer keeps animating
  // indefinitely (we removed the implicit-close fallbacks on the Shell side
  // when the lifecycle moved to an explicit channel).
  let thinkingOpen = false;
  const closeThinkingIfOpen = (): void => {
    if (!thinkingOpen) return;
    thinkingOpen = false;
    dispatcher.notify(RPCMethod.uiThinking, { sessionId, turnId, kind: "end" });
  };

  try {
    // Pull the rolling LLM history from the Conversation. This is the
    // single change that gives the LLM cross-turn memory: prior successful
    // turns contribute their (user, assistant) pair; the just-started turn
    // contributes its user message; errored/cancelled turns are skipped.
    const messages = convo.llmMessages();

    // Dev-mode observability: capture the exact (systemPrompt, messages)
    // pair we are about to hand to the LLM. Publish BEFORE the network
    // call so a Dev Mode window opened mid-turn always sees the latest
    // input, not a stale snapshot. The observer swallows sink failures
    // — observation must never break the turn.
    observer.publish({
      capturedAt: Date.now(),
      sessionId,
      turnId,
      modelId: model.id,
      providerId: model.provider,
      effort: effort ?? null,
      systemPrompt: SYSTEM_PROMPT,
      messagesJson: ContextObserver.renderMessages(messages),
    });

    const eventStream = streamSimple(
      model,
      {
        systemPrompt: SYSTEM_PROMPT,
        messages,
      },
      { signal, reasoning: effort },
    );

    let final: AssistantMessage | undefined;
    for await (const ev of eventStream) {
      if (signal.aborted) break;
      if (ev.type === "thinking_delta") {
        // Forward reasoning-trace deltas verbatim. Not persisted in the
        // Conversation store: thinking is display-only and never replayed
        // into the next turn's LLM context (cross-source providers strip
        // it anyway). The Shell renders these in a separate affordance.
        thinkingOpen = true;
        dispatcher.notify(RPCMethod.uiThinking, {
          sessionId,
          turnId,
          kind: "delta",
          delta: ev.delta,
        });
      } else if (ev.type === "thinking_end") {
        // Explicit lifecycle end of the current reasoning block. Forwarded
        // so the Shell can stamp `thinkingEndedAt` without inferring it
        // from the first `ui.token` (which never arrives for tool-call-
        // only turns or when reasoning ends right at completion).
        closeThinkingIfOpen();
      } else if (ev.type === "text_delta") {
        // Dual write: durable Conversation first, then streaming notify.
        // The boolean tells us whether the turn still exists — false means
        // it was wiped by `agent.reset` / advanced past by `agent.cancel`,
        // which is the only legitimate race. In that case we MUST NOT emit
        // a `ui.token` for a turn the Shell mirror has already dropped, or
        // the two views diverge.
        if (convo.appendDelta(turnId, ev.delta)) {
          dispatcher.notify(RPCMethod.uiToken, { sessionId, turnId, delta: ev.delta });
        }
      } else if (ev.type === "done") {
        final = ev.message;
      } else if (ev.type === "error") {
        const code = pickErrorCode(ev.error);
        const message = ev.error.errorMessage ?? "agent error";
        // Close any open reasoning block first — the Shell stamps
        // `thinkingEndedAt` on this and stops the shimmer.
        closeThinkingIfOpen();
        if (convo.setError(turnId, code, message)) {
          dispatcher.notify(RPCMethod.uiError, { sessionId, turnId, code, message });
          // Project typed auth invalidation to provider.statusChanged so the
          // Shell ProviderService flips to unauthenticated and the next
          // opened-state shows the onboard panel. Per docs/plans/onboarding.md
          // "typed auth error 传播": llm/ does not import dispatcher; the
          // projection lives here at the agent loop boundary.
          if (ev.error.errorReason === "authInvalidated" && ev.error.errorProviderId) {
            dispatcher.notify(RPCMethod.providerStatusChanged, {
              providerId: ev.error.errorProviderId,
              state: "unauthenticated",
              reason: "authInvalidated",
              message,
            });
          }
        }
        return;
      }
    }

    if (final && isContextOverflow(final, model.contextWindow)) {
      // Allocated agent.* segment (-32300 ~ -32399) per rpc-protocol.md.
      // contextOverflow = -32300; distinguishes overflow from generic
      // internal faults so the Shell error UI can render a tailored message.
      closeThinkingIfOpen();
      if (convo.setError(turnId, RPCErrorCode.agentContextOverflow, "Context too long")) {
        dispatcher.notify(RPCMethod.uiError, {
          sessionId,
          turnId,
          code: RPCErrorCode.agentContextOverflow,
          message: "Context too long",
        });
      }
      return;
    }

    // Natural completion vs. cancellation:
    //   - natural: store the final AssistantMessage so the next request
    //     replays this turn into the LLM context.
    //   - cancellation: leave status in `cancelled` (set by agent.cancel) so
    //     llmMessages() skips it. We still emit `ui.status done` so the
    //     Notch UI reaches the same terminal emoji state.
    if (final && !signal.aborted) {
      const ok = convo.markDone(turnId, final);
      // Re-publish so Dev Mode reflects the full turn (user + assistant)
      // instead of frozen pre-call input. Pull fresh `llmMessages()` so
      // the snapshot includes the just-stored AssistantMessage.
      observer.publish({
        capturedAt: Date.now(),
        sessionId,
        turnId,
        modelId: model.id,
        providerId: model.provider,
        effort: effort ?? null,
        systemPrompt: SYSTEM_PROMPT,
        messagesJson: ContextObserver.renderMessages(convo.llmMessages()),
      });
      // turnCount + lastActivityAt advanced — surface to the history list.
      // Skip when `markDone` returned false (turn was reset/cancelled mid-flight).
      if (ok) params.onDone?.();
    }
    // `ui.status done` is the terminal signal regardless of whether the turn
    // is still in the conversation — Shell may want to clear its emoji even
    // if the turn was reset. We notify unconditionally here. Cancel paths
    // also land here (loop break on `signal.aborted`) — closing the thinking
    // block first keeps the cancel-mid-thinking UX consistent with errors.
    closeThinkingIfOpen();
    dispatcher.notify(RPCMethod.uiStatus, { sessionId, turnId, status: "done" });
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    logger.error("runTurn failed", { turnId, err: String(err) });
    closeThinkingIfOpen();
    if (convo.setError(turnId, RPCErrorCode.internalError, message)) {
      dispatcher.notify(RPCMethod.uiError, {
        sessionId,
        turnId,
        code: RPCErrorCode.internalError,
        message,
      });
    }
  }
}
