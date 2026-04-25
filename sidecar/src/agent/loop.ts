// Agent turn loop — bridges `agent.submit` / `agent.cancel` to the `llm/` stream.
//
// Per docs/designs/rpc-protocol.md §"流式语义":
//   1. agent.submit Request returns { accepted: true } immediately. The actual
//      LLM streaming happens in a detached background task.
//   2. While streaming, ui.status, ui.token, ui.error notifications are pushed.
//   3. agent.cancel triggers the per-turn AbortController; the stream loop
//      observes `signal.aborted`, breaks out, and emits `ui.status done`.
//
// Per docs/designs/llm-provider.md §"包边界" the loop only depends on the
// public surface re-exported from `../llm`.

import { stream, getModel, isContextOverflow, type AssistantMessage, type Model, type Api } from "../llm";
import {
  RPCErrorCode,
  RPCMethod,
  type AgentSubmitParams,
  type AgentSubmitResult,
  type AgentCancelParams,
  type AgentCancelResult,
} from "../rpc/rpc-types";
import { Dispatcher, RPCMethodError } from "../rpc/dispatcher";
import { turns, type TurnRegistry } from "./registry";
import { logger } from "../log";

const SYSTEM_PROMPT = "You are AOS, an AI agent embedded in macOS via the notch UI. Be concise and helpful.";

// ---------------------------------------------------------------------------
// Test injection point.
//
// Tests substitute the model resolver so a fake model + fake stream provider
// can be wired in without touching the global model / api registries. Default
// is the catalog lookup for the production chatgpt-plan / gpt-5-2 entry.
// ---------------------------------------------------------------------------

type ModelResolver = () => Model<Api>;

let modelResolver: ModelResolver = () => getModel("chatgpt-plan", "gpt-5-2");

export function setModelResolver(fn: ModelResolver): void {
  modelResolver = fn;
}

export function resetModelResolver(): void {
  modelResolver = () => getModel("chatgpt-plan", "gpt-5-2");
}

// ---------------------------------------------------------------------------
// Error code mapping
// ---------------------------------------------------------------------------

/// Per design risk note: ErrPermissionDenied (-32003) covers auth failures
/// (missing/expired ChatGPT token, 401 from upstream). Everything else is
/// surfaced as a generic InternalError until the agent.* error segment
/// (-32300 ~ -32399) is finalized.
export function pickErrorCode(msg: AssistantMessage): number {
  const text = msg.errorMessage ?? "";
  if (/auth|unauthorized|401|<authenticated>/i.test(text)) {
    return RPCErrorCode.permissionDenied;
  }
  return RPCErrorCode.internalError;
}

// ---------------------------------------------------------------------------
// Handler registration
// ---------------------------------------------------------------------------

export interface RegisterAgentOptions {
  /// Override the registry (tests use a private one to avoid leaking state).
  registry?: TurnRegistry;
}

export function registerAgentHandlers(dispatcher: Dispatcher, opts: RegisterAgentOptions = {}): void {
  const reg = opts.registry ?? turns;

  dispatcher.registerRequest(RPCMethod.agentSubmit, async (raw): Promise<AgentSubmitResult> => {
    const params = raw as AgentSubmitParams;
    const { turnId, prompt } = params;
    if (typeof turnId !== "string" || typeof prompt !== "string") {
      throw new RPCMethodError(RPCErrorCode.invalidParams, "agent.submit requires { turnId, prompt }");
    }
    if (reg.get(turnId)) {
      throw new RPCMethodError(RPCErrorCode.invalidRequest, `turnId already active: ${turnId}`);
    }
    const controller = reg.add(turnId);

    // Detached: ack must return inside agent.submit's 1s budget.
    void runTurn(dispatcher, { turnId, prompt, signal: controller.signal })
      .catch((err) => logger.error("agent loop fatal", { turnId, err: String(err) }))
      .finally(() => reg.remove(turnId));

    return { accepted: true };
  });

  dispatcher.registerRequest(RPCMethod.agentCancel, async (raw): Promise<AgentCancelResult> => {
    const { turnId } = raw as AgentCancelParams;
    if (typeof turnId !== "string") {
      throw new RPCMethodError(RPCErrorCode.invalidParams, "agent.cancel requires { turnId }");
    }
    return { cancelled: reg.abort(turnId) };
  });
}

// ---------------------------------------------------------------------------
// runTurn — exported for tests
// ---------------------------------------------------------------------------

export async function runTurn(
  dispatcher: Dispatcher,
  params: { turnId: string; prompt: string; signal: AbortSignal },
): Promise<void> {
  const { turnId, prompt, signal } = params;

  dispatcher.notify(RPCMethod.uiStatus, { turnId, status: "thinking" });

  let model: Model<Api>;
  try {
    model = modelResolver();
  } catch (err) {
    logger.error("model resolution failed", { turnId, err: String(err) });
    dispatcher.notify(RPCMethod.uiError, {
      turnId,
      code: RPCErrorCode.internalError,
      message: err instanceof Error ? err.message : String(err),
    });
    return;
  }

  try {
    const eventStream = stream(
      model,
      {
        systemPrompt: SYSTEM_PROMPT,
        messages: [{ role: "user", content: prompt, timestamp: Date.now() }],
      },
      { signal },
    );

    let final: AssistantMessage | undefined;
    for await (const ev of eventStream) {
      if (signal.aborted) break;
      if (ev.type === "text_delta") {
        dispatcher.notify(RPCMethod.uiToken, { turnId, delta: ev.delta });
      } else if (ev.type === "done") {
        final = ev.message;
      } else if (ev.type === "error") {
        const code = pickErrorCode(ev.error);
        dispatcher.notify(RPCMethod.uiError, {
          turnId,
          code,
          message: ev.error.errorMessage ?? "agent error",
        });
        return;
      }
    }

    if (final && isContextOverflow(final, model.contextWindow)) {
      dispatcher.notify(RPCMethod.uiError, {
        turnId,
        // TBD: agent.* error segment (-32300 ~ -32399) per rpc-protocol.md
        // risk note. Until that's allocated, surface as InvalidParams so the
        // Shell-side error UI distinguishes it from a generic internal fault.
        code: RPCErrorCode.invalidParams,
        message: "Context too long",
      });
      return;
    }

    // Both cancellation and natural completion end with ui.status done so the
    // Notch UI reaches the same terminal emoji state.
    dispatcher.notify(RPCMethod.uiStatus, { turnId, status: "done" });
  } catch (err) {
    logger.error("runTurn failed", { turnId, err: String(err) });
    dispatcher.notify(RPCMethod.uiError, {
      turnId,
      code: RPCErrorCode.internalError,
      message: err instanceof Error ? err.message : String(err),
    });
  }
}
