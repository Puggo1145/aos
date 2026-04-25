// Helpers shared by every `streamSimple*` provider implementation.
//
// `buildBaseOptions` collapses a `SimpleStreamOptions` into the parent
// `StreamOptions` shape (everything except `reasoning` and
// `thinkingBudgets`, which the caller has to translate per provider).
// `clampReasoning` is a pure mapping for providers that only accept a
// subset of effort levels. `adjustMaxTokensForThinking` adds a small
// budget on top of the user-requested maxTokens when reasoning is on,
// so a long thought process does not eat the visible answer.

import type {
  Model,
  SimpleStreamOptions,
  StreamOptions,
  ThinkingLevel,
} from "../types";
import { supportsXhigh } from "../models/capabilities";

export function buildBaseOptions(simple: SimpleStreamOptions | undefined): StreamOptions {
  if (!simple) return {};
  const { reasoning: _r, thinkingBudgets: _tb, ...base } = simple;
  return base;
}

/// Clamp `xhigh` down to `high` when the model does not declare xhigh
/// support. Keeps the rest of the levels unchanged.
export function clampReasoning<TApi extends import("../types").Api>(
  level: ThinkingLevel | undefined,
  model: Model<TApi>,
): ThinkingLevel | undefined {
  if (!level) return undefined;
  if (level === "xhigh" && !supportsXhigh(model)) return "high";
  return level;
}

/// Bump `maxTokens` to leave room for thinking. Returns the original
/// value when reasoning is `minimal` or unset.
export function adjustMaxTokensForThinking<TApi extends import("../types").Api>(
  maxTokens: number | undefined,
  level: ThinkingLevel | undefined,
  model: Model<TApi>,
): number | undefined {
  if (!maxTokens || !level || level === "minimal") return maxTokens;
  const budget: Record<ThinkingLevel, number> = {
    minimal: 0,
    low: 1024,
    medium: 4096,
    high: 16_384,
    xhigh: 32_768,
  };
  const extra = budget[level] ?? 0;
  const total = maxTokens + extra;
  return Math.min(total, model.maxTokens);
}
