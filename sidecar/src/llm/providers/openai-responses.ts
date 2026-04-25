// OpenAI Responses API streaming provider.
//
// =====================================================================
// INTEGRATION NOTE — VERIFY before first real-endpoint smoke test
// =====================================================================
// The exact SSE event names emitted by the OpenAI Responses API are
// subject to upstream protocol revision and (for the ChatGPT plan
// endpoint specifically) have not been formally published.
//
// Below we map a best-effort dispatch table covering the documented
// `response.created`, `response.output_item.added/.done`,
// `response.output_text.delta/.done`,
// `response.reasoning_text.delta/.done`,
// `response.function_call_arguments.delta/.done`,
// `response.completed`, `response.failed` events.
//
// The dispatch is centralized in `mapResponsesEventToAssistantEvent` so
// that adjusting it for the real endpoint requires editing one function.
// Unknown events are logged to stderr and otherwise ignored (per design
// doc "风险" item: "OpenAI Responses 协议未来字段变更" → only log).
// =====================================================================

import { createParser, type EventSourceMessage } from "eventsource-parser";

import type {
  AssistantMessage,
  AssistantMessageEvent,
  Context,
  Message,
  Model,
  ProviderStreamOptions,
  SimpleStreamFunction,
  SimpleStreamOptions,
  StreamFunction,
  TextContent,
  ThinkingContent,
  ToolCall,
  Usage,
} from "../types";
import { AssistantMessageEventStream } from "../utils/event-stream";
import { calculateCost } from "../models/cost";
import { sanitizeSurrogates } from "../utils/sanitize-unicode";
import { mergeHeaders } from "../utils/headers";
import { parseStreamingJson } from "../utils/json-parse";
import {
  AUTHENTICATED_SENTINEL,
  getEnvApiKey,
} from "../auth/env-api-keys";
import { readChatGPTToken } from "../auth/oauth/chatgpt-plan";
import { buildBaseOptions, clampReasoning } from "./simple-options";

export interface OpenAIResponsesOptions extends ProviderStreamOptions {
  reasoning?: import("../types").ThinkingLevel;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function emptyUsage(): Usage {
  return {
    input: 0,
    output: 0,
    cacheRead: 0,
    cacheWrite: 0,
    totalTokens: 0,
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
  };
}

function makeOutput<TApi extends "openai-responses">(model: Model<TApi>): AssistantMessage {
  return {
    role: "assistant",
    content: [],
    api: model.api,
    provider: model.provider,
    model: model.id,
    usage: emptyUsage(),
    stopReason: "stop",
    timestamp: Date.now(),
  };
}

function buildPayload(model: Model<"openai-responses">, context: Context, options?: OpenAIResponsesOptions): Record<string, unknown> {
  const input: Array<Record<string, unknown>> = [];
  if (context.systemPrompt) {
    input.push({ role: "system", content: [{ type: "input_text", text: sanitizeSurrogates(context.systemPrompt) }] });
  }
  for (const msg of context.messages) {
    input.push(serializeMessage(msg));
  }
  const payload: Record<string, unknown> = {
    model: model.id,
    input,
    stream: true,
  };
  if (options?.maxTokens) payload["max_output_tokens"] = options.maxTokens;
  if (options?.temperature !== undefined) payload["temperature"] = options.temperature;
  if (options?.reasoning) payload["reasoning"] = { effort: options.reasoning };
  if (context.tools && context.tools.length > 0) {
    payload["tools"] = context.tools.map((t) => ({
      type: "function",
      name: t.name,
      description: t.description,
      parameters: t.parameters,
    }));
  }
  return payload;
}

function serializeMessage(msg: Message): Record<string, unknown> {
  if (msg.role === "user") {
    const content = typeof msg.content === "string"
      ? [{ type: "input_text", text: sanitizeSurrogates(msg.content) }]
      : msg.content.map((b) => b.type === "text"
          ? { type: "input_text", text: sanitizeSurrogates(b.text) }
          : { type: "input_image", image_url: `data:${b.mimeType};base64,${b.data}` });
    return { role: "user", content };
  }
  if (msg.role === "assistant") {
    const content: Record<string, unknown>[] = [];
    for (const block of msg.content) {
      if (block.type === "text") {
        content.push({ type: "output_text", text: sanitizeSurrogates(block.text) });
      } else if (block.type === "thinking") {
        content.push({ type: "reasoning", text: sanitizeSurrogates(block.thinking), signature: block.thinkingSignature });
      } else if (block.type === "toolCall") {
        content.push({ type: "function_call", call_id: block.id, name: block.name, arguments: JSON.stringify(block.arguments) });
      }
    }
    return { role: "assistant", content };
  }
  // toolResult
  const content = msg.content.map((b) => b.type === "text"
    ? { type: "input_text", text: sanitizeSurrogates(b.text) }
    : { type: "input_image", image_url: `data:${b.mimeType};base64,${b.data}` });
  return { type: "function_call_output", call_id: msg.toolCallId, output: content };
}

function mapStopReason(status: string | undefined, incompleteReason: string | undefined): "stop" | "length" | "toolUse" | "error" {
  if (status === "completed") return "stop";
  if (status === "incomplete") {
    if (incompleteReason === "max_output_tokens") return "length";
    if (incompleteReason === "content_filter") return "error";
    throw new Error(`Unhandled incomplete reason: ${incompleteReason}`);
  }
  if (status === "failed") return "error";
  if (status === "requires_action" || status === "in_progress") return "toolUse";
  throw new Error(`Unhandled response status: ${status}`);
}

function applyUsage(model: Model<"openai-responses">, output: AssistantMessage, raw: Record<string, unknown> | undefined): void {
  if (!raw) return;
  const input = Number(raw["input_tokens"] ?? 0);
  const outputTokens = Number(raw["output_tokens"] ?? 0);
  const details = (raw["input_tokens_details"] as Record<string, unknown> | undefined) ?? {};
  const cacheRead = Number(details["cached_tokens"] ?? 0);
  const cacheWrite = Number(details["cache_creation_tokens"] ?? 0);
  output.usage.input = input - cacheRead - cacheWrite;
  if (output.usage.input < 0) output.usage.input = input;
  output.usage.output = outputTokens;
  output.usage.cacheRead = cacheRead;
  output.usage.cacheWrite = cacheWrite;
  output.usage.totalTokens = output.usage.input + output.usage.output + output.usage.cacheRead + output.usage.cacheWrite;
  calculateCost(model, output.usage);
}

// ---------------------------------------------------------------------------
// Main stream function
// ---------------------------------------------------------------------------

export const streamOpenaiResponses: StreamFunction<"openai-responses", OpenAIResponsesOptions> = (model, context, options) => {
  const stream = new AssistantMessageEventStream();
  const output = makeOutput(model);

  const blocks = new Map<number, { kind: "text" | "thinking" | "toolCall"; partialJson?: string }>();

  // Resolve a unique content index across all kinds (matches the
  // event protocol's `contentIndex` field). We assign the index when
  // an output_item is "added" and reuse it for delta / done.
  const itemIndexToContent = new Map<string, number>();

  void (async () => {
    try {
      // 1. Auth
      const headers: Record<string, string> = {
        "content-type": "application/json",
        accept: "text/event-stream",
      };
      const apiKey = options?.apiKey ?? getEnvApiKey(model.provider);
      if (apiKey === AUTHENTICATED_SENTINEL) {
        const token = await readChatGPTToken();
        headers["authorization"] = `Bearer ${token.accessToken}`;
        if (token.accountId) headers["chatgpt-account-id"] = token.accountId;
      } else if (typeof apiKey === "string" && apiKey.length > 0) {
        headers["authorization"] = `Bearer ${apiKey}`;
      } else {
        throw new Error("ChatGPT 订阅未授权");
      }
      const finalHeaders = mergeHeaders(headers, model.headers, options?.headers);

      // 2. Build payload
      let payload: unknown = buildPayload(model, context, options);
      if (options?.onPayload) {
        const overridden = await options.onPayload(payload, model);
        if (overridden !== undefined) payload = overridden;
      }

      // 3. Issue request
      stream.push({ type: "start", partial: output });

      const url = `${model.baseUrl.replace(/\/$/, "")}/responses`;
      const res = await fetch(url, {
        method: "POST",
        headers: finalHeaders,
        body: JSON.stringify(payload),
        signal: options?.signal,
      });
      if (options?.onResponse) {
        const hr: Record<string, string> = {};
        res.headers.forEach((v, k) => { hr[k.toLowerCase()] = v; });
        await options.onResponse({ status: res.status, headers: hr }, model);
      }
      if (!res.ok || !res.body) {
        const text = await res.text().catch(() => "");
        throw new Error(`HTTP ${res.status}: ${text || "(no body)"}`);
      }

      // 4. SSE parse
      const parser = createParser({
        onEvent: (ev: EventSourceMessage) => {
          try {
            mapResponsesEventToAssistantEvent(ev, model, output, blocks, itemIndexToContent, stream);
          } catch (err) {
            // Per design doc: unknown events log to stderr but do not abort.
            process.stderr.write(`[openai-responses] event mapping error: ${err instanceof Error ? err.message : String(err)}\n`);
          }
        },
      });

      const reader = res.body.getReader();
      const decoder = new TextDecoder();
      while (true) {
        if (options?.signal?.aborted) throw new DOMException("aborted", "AbortError");
        const { value, done } = await reader.read();
        if (done) break;
        parser.feed(decoder.decode(value, { stream: true }));
      }

      // 5. Cleanup partial fields and emit `done`.
      cleanupPartials(output);
      stream.push({ type: "done", reason: output.stopReason === "length" ? "length" : output.stopReason === "toolUse" ? "toolUse" : "stop", message: output });
      stream.end();
    } catch (error) {
      cleanupPartials(output);
      output.stopReason = options?.signal?.aborted ? "aborted" : "error";
      output.errorMessage = error instanceof Error ? error.message : JSON.stringify(error);
      stream.push({ type: "error", reason: output.stopReason, error: output });
      stream.end();
    }
  })();

  return stream;
};

function cleanupPartials(output: AssistantMessage): void {
  for (const block of output.content as unknown as Array<Record<string, unknown>>) {
    delete block["partialJson"];
    delete block["index"];
  }
}

// ---------------------------------------------------------------------------
// SSE event → AssistantMessageEvent dispatch
// ---------------------------------------------------------------------------

function mapResponsesEventToAssistantEvent(
  ev: EventSourceMessage,
  model: Model<"openai-responses">,
  output: AssistantMessage,
  blocks: Map<number, { kind: "text" | "thinking" | "toolCall"; partialJson?: string }>,
  itemIndexToContent: Map<string, number>,
  stream: AssistantMessageEventStream,
): void {
  if (!ev.event || !ev.data) return;
  let payload: Record<string, unknown> = {};
  try { payload = JSON.parse(ev.data); } catch { return; }

  const type = ev.event;

  if (type === "response.created" || type === "response.in_progress") {
    const usage = (payload["response"] as Record<string, unknown> | undefined)?.["usage"] as Record<string, unknown> | undefined;
    applyUsage(model, output, usage);
    return;
  }

  if (type === "response.output_item.added") {
    const item = payload["item"] as Record<string, unknown> | undefined;
    const itemId = String(payload["item_id"] ?? item?.["id"] ?? "");
    const itemType = String(item?.["type"] ?? "");
    const contentIndex = output.content.length;
    if (itemId) itemIndexToContent.set(itemId, contentIndex);

    if (itemType === "message" || itemType === "output_text") {
      const block: TextContent = { type: "text", text: "" };
      output.content.push(block);
      blocks.set(contentIndex, { kind: "text" });
      stream.push({ type: "text_start", contentIndex, partial: output });
    } else if (itemType === "reasoning") {
      const block: ThinkingContent = { type: "thinking", thinking: "" };
      output.content.push(block);
      blocks.set(contentIndex, { kind: "thinking" });
      stream.push({ type: "thinking_start", contentIndex, partial: output });
    } else if (itemType === "function_call") {
      const block: ToolCall = {
        type: "toolCall",
        id: String(item?.["call_id"] ?? item?.["id"] ?? ""),
        name: String(item?.["name"] ?? ""),
        arguments: {},
      };
      output.content.push(block);
      blocks.set(contentIndex, { kind: "toolCall", partialJson: "" });
      stream.push({ type: "toolcall_start", contentIndex, partial: output });
    }
    return;
  }

  if (type === "response.output_text.delta") {
    const itemId = String(payload["item_id"] ?? "");
    const idx = itemIndexToContent.get(itemId);
    if (idx === undefined) return;
    const delta = String(payload["delta"] ?? "");
    const block = output.content[idx] as TextContent;
    block.text += delta;
    stream.push({ type: "text_delta", contentIndex: idx, delta, partial: output });
    return;
  }

  if (type === "response.output_text.done") {
    const itemId = String(payload["item_id"] ?? "");
    const idx = itemIndexToContent.get(itemId);
    if (idx === undefined) return;
    const block = output.content[idx] as TextContent;
    const text = String(payload["text"] ?? block.text);
    block.text = text;
    stream.push({ type: "text_end", contentIndex: idx, content: text, partial: output });
    return;
  }

  if (type === "response.reasoning_text.delta" || type === "response.reasoning_summary_text.delta") {
    const itemId = String(payload["item_id"] ?? "");
    const idx = itemIndexToContent.get(itemId);
    if (idx === undefined) return;
    const delta = String(payload["delta"] ?? "");
    const block = output.content[idx] as ThinkingContent;
    block.thinking += delta;
    stream.push({ type: "thinking_delta", contentIndex: idx, delta, partial: output });
    return;
  }

  if (type === "response.reasoning_text.done" || type === "response.reasoning_summary_text.done") {
    const itemId = String(payload["item_id"] ?? "");
    const idx = itemIndexToContent.get(itemId);
    if (idx === undefined) return;
    const block = output.content[idx] as ThinkingContent;
    const text = String(payload["text"] ?? block.thinking);
    block.thinking = text;
    stream.push({ type: "thinking_end", contentIndex: idx, content: text, partial: output });
    return;
  }

  if (type === "response.function_call_arguments.delta") {
    const itemId = String(payload["item_id"] ?? "");
    const idx = itemIndexToContent.get(itemId);
    if (idx === undefined) return;
    const meta = blocks.get(idx);
    if (!meta || meta.kind !== "toolCall") return;
    const delta = String(payload["delta"] ?? "");
    meta.partialJson = (meta.partialJson ?? "") + delta;
    const block = output.content[idx] as ToolCall;
    block.arguments = parseStreamingJson(meta.partialJson) as Record<string, unknown>;
    stream.push({ type: "toolcall_delta", contentIndex: idx, delta, partial: output });
    return;
  }

  if (type === "response.function_call_arguments.done") {
    const itemId = String(payload["item_id"] ?? "");
    const idx = itemIndexToContent.get(itemId);
    if (idx === undefined) return;
    const meta = blocks.get(idx);
    if (!meta || meta.kind !== "toolCall") return;
    const final = String(payload["arguments"] ?? meta.partialJson ?? "");
    const block = output.content[idx] as ToolCall;
    try { block.arguments = JSON.parse(final); } catch { block.arguments = parseStreamingJson(final) as Record<string, unknown>; }
    stream.push({ type: "toolcall_end", contentIndex: idx, toolCall: block, partial: output });
    return;
  }

  if (type === "response.completed") {
    const response = payload["response"] as Record<string, unknown> | undefined;
    applyUsage(model, output, response?.["usage"] as Record<string, unknown> | undefined);
    const status = response?.["status"] as string | undefined;
    const incomplete = (response?.["incomplete_details"] as Record<string, unknown> | undefined)?.["reason"] as string | undefined;
    output.responseId = response?.["id"] as string | undefined;
    output.stopReason = mapStopReason(status, incomplete);
    return;
  }

  if (type === "response.failed" || type === "error") {
    const errObj = (payload["response"] as Record<string, unknown> | undefined)?.["error"] ?? payload["error"] ?? payload;
    const message = (errObj as Record<string, unknown>)?.["message"] ?? JSON.stringify(errObj);
    throw new Error(typeof message === "string" ? message : JSON.stringify(message));
  }

  // Unknown / future events: silently ignored at this level.
}

// ---------------------------------------------------------------------------
// Simple wrapper
// ---------------------------------------------------------------------------

export const streamSimpleOpenaiResponses: SimpleStreamFunction<"openai-responses"> = (model, context, simple?: SimpleStreamOptions) => {
  const base = buildBaseOptions(simple);
  const reasoning = clampReasoning(simple?.reasoning, model);
  return streamOpenaiResponses(model, context, { ...base, reasoning });
};
