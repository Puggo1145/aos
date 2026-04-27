// DeepSeek provider — thin wrapper over `openai-completions`.
//
// DeepSeek is OpenAI Chat-Completions compatible, but rejects a handful of
// fields that vanilla OpenAI accepts. We isolate those quirks in a single
// `compat` object and delegate the actual streaming engine to
// `runCompletionsStream`. Per docs/designs/llm-provider.md "包边界" this file
// is the *only* place that knows about DeepSeek-specific behavior.
//
// Quirks captured here (sourced from api-docs.deepseek.com, 2026-04-26):
//   - Rejects `store: false` and the `developer` system role → both off.
//   - Does not implement `reasoning_effort`. Effort levels are silently
//     accepted by the SDK but produce no behavior change → suppressed.
//   - Reasoning text streams via `delta.reasoning_content` (not `reasoning`).
//   - The `max_tokens` field is the legacy spelling — DeepSeek's docs use
//     it exclusively, `max_completion_tokens` is unrecognized.
//   - Echoing prior-turn `reasoning_content` back into messages causes a
//     400. We already drop assistant `thinking` blocks at convertMessages
//     time in `openai-completions.ts`, so no extra handling here.

import type {
  SimpleStreamFunction,
  SimpleStreamOptions,
  StreamFunction,
} from "../types";
import {
  type OpenAICompletionsCompat,
  type OpenAICompletionsOptions,
  resolveCompat,
  runCompletionsStream,
} from "./openai-completions";
import { buildBaseOptions, clampReasoning } from "./simple-options";

const DEEPSEEK_COMPAT_RAW: OpenAICompletionsCompat = {
  supportsStore: false,
  supportsDeveloperRole: false,
  supportsReasoningEffort: false,
  maxTokensField: "max_tokens",
  reasoningField: "reasoning_content",
  requiresToolResultName: false,
};

const DEEPSEEK_COMPAT = resolveCompat(DEEPSEEK_COMPAT_RAW);

export const streamDeepseek: StreamFunction<"deepseek", OpenAICompletionsOptions> = (
  model,
  context,
  options,
) => runCompletionsStream(model, context, options, DEEPSEEK_COMPAT);

export const streamSimpleDeepseek: SimpleStreamFunction<"deepseek"> = (
  model,
  context,
  simple?: SimpleStreamOptions,
) => {
  const base = buildBaseOptions(simple);
  // Even though DeepSeek ignores `reasoning_effort`, we still clamp here
  // for symmetry with other providers; the field is stripped inside
  // `buildPayload` based on `compat.supportsReasoningEffort: false`.
  const reasoningEffort = clampReasoning(simple?.reasoning, model);
  return runCompletionsStream(model, context, { ...base, reasoningEffort }, DEEPSEEK_COMPAT);
};
