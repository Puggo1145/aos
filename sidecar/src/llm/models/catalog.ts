// Built-in model & provider catalog — single source of truth.
//
// Runtime code MUST NOT hardcode provider ids, model ids, display names,
// or default-model selection. Import the constants exported here.
//
// Notes per docs/designs/llm-provider.md:
//   - `baseUrl` matches our `openai-responses` provider, which appends
//     `/responses`. The upstream URL the requests resolve to is
//     `https://chatgpt.com/backend-api/codex/responses` (same as pi-mono's
//     `resolveCodexUrl`).
//   - `cost: 0` because ChatGPT plan is a flat-rate subscription;
//     `calculateCost` still runs and returns 0, so call sites don't change
//     when a metered provider is added later.
//   - `input: ["text", "image"]` declares capability; this round AOS never
//     sends image content, but `transformMessages` reads this field so
//     future image input requires no edits here.
//   - `reasoning: true` powers `supportsXhigh` and the `streamSimple`
//     reasoning-effort mapping.

import type { Api, Model } from "../types";

export const MODELS = {
  "chatgpt-plan": {
    "gpt-5.5": {
      id: "gpt-5.5",
      name: "GPT-5.5",
      api: "openai-responses",
      provider: "chatgpt-plan",
      baseUrl: "https://chatgpt.com/backend-api/codex",
      reasoning: true,
      input: ["text", "image"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      contextWindow: 400_000,
      maxTokens: 128_000,
    },
    "gpt-5.4": {
      id: "gpt-5.4",
      name: "GPT-5.4",
      api: "openai-responses",
      provider: "chatgpt-plan",
      baseUrl: "https://chatgpt.com/backend-api/codex",
      reasoning: true,
      input: ["text", "image"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      contextWindow: 272_000,
      maxTokens: 128_000,
    },
    "gpt-5.3-codex": {
      id: "gpt-5.3-codex",
      name: "GPT-5.3 Codex",
      api: "openai-responses",
      provider: "chatgpt-plan",
      baseUrl: "https://chatgpt.com/backend-api/codex",
      reasoning: true,
      input: ["text", "image"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      contextWindow: 272_000,
      maxTokens: 128_000,
    },
  },
  // Sourced from api-docs.deepseek.com (2026-04-26). Both models stream
  // reasoning via `delta.reasoning_content` and bill cache reads at a steep
  // discount; cache writes are not separately billed (`cacheWrite: 0`).
  "deepseek": {
    "deepseek-v4-flash": {
      id: "deepseek-v4-flash",
      name: "DeepSeek V4 Flash",
      api: "deepseek",
      provider: "deepseek",
      baseUrl: "https://api.deepseek.com",
      reasoning: true,
      input: ["text"],
      cost: { input: 0.14, output: 0.28, cacheRead: 0.0028, cacheWrite: 0 },
      contextWindow: 1_000_000,
      maxTokens: 384_000,
    },
    "deepseek-v4-pro": {
      id: "deepseek-v4-pro",
      name: "DeepSeek V4 Pro",
      api: "deepseek",
      provider: "deepseek",
      baseUrl: "https://api.deepseek.com",
      reasoning: true,
      input: ["text"],
      cost: { input: 0.435, output: 0.87, cacheRead: 0.003625, cacheWrite: 0 },
      contextWindow: 1_000_000,
      maxTokens: 384_000,
    },
  },
} as const satisfies Record<string, Record<string, Model<Api>>>;

export type KnownProvider = keyof typeof MODELS;
export type KnownModelId<P extends KnownProvider> = keyof (typeof MODELS)[P];

/// Stable provider-id constants. Runtime code references these rather
/// than the bare string literal, so a future rename only touches this
/// file. `satisfies` ensures every value is an actual catalog key.
export const PROVIDER_IDS = {
  chatgptPlan: "chatgpt-plan",
  deepseek: "deepseek",
} as const satisfies Record<string, KnownProvider>;

/// Human-readable display names (shown in Onboarding cards, model
/// pickers, etc). Keyed by the same provider id as `MODELS`.
export const PROVIDER_NAMES: Record<KnownProvider, string> = {
  "chatgpt-plan": "Codex Subscription",
  "deepseek": "DeepSeek",
};

/// Default model id per provider. Used when no explicit selection is
/// configured (boot, fresh session, etc).
export const DEFAULT_MODEL_PER_PROVIDER: { [P in KnownProvider]: KnownModelId<P> } = {
  "chatgpt-plan": "gpt-5.5",
  "deepseek": "deepseek-v4-flash",
};

/// Reasoning effort enum. Mirrors `ThinkingLevel` from `../types`; declared
/// here so the catalog stays the single source of truth for "what values
/// are valid". Order is the canonical low→high progression used by the
/// settings UI.
export const EFFORT_LEVELS = ["minimal", "low", "medium", "high", "xhigh"] as const;
export type Effort = (typeof EFFORT_LEVELS)[number];

/// Global default effort when the user has never picked one. Mirrors pi's
/// `DEFAULT_THINKING_LEVEL = "medium"`.
export const DEFAULT_EFFORT: Effort = "medium";

/// Convenience: look up a model object's `api` field from the catalog.
/// Used by callers that want to keep `Api` types tight.
export type ModelApiOf<P extends KnownProvider, M extends KnownModelId<P>> =
  (typeof MODELS)[P][M] extends Model<infer A extends Api> ? A : never;
