// Built-in model catalog.
//
// AOS only ships one entry this round: `gpt-5-2` under provider
// `chatgpt-plan`. The catalog uses `as const` so `getModel(provider,
// modelId)` can refine the `Model<TApi>` type parameter at compile time.
//
// Notes per docs/designs/llm-provider.md:
//   - `baseUrl` is tentative pending OAuth / endpoint confirmation
//     (see "风险" section). Updating it is a one-line change with no
//     impact on other modules.
//   - `cost: 0` everywhere because ChatGPT subscription is flat-rate;
//     `calculateCost` still runs and returns 0, so call sites continue
//     to work unchanged when AOS later switches to a metered provider.
//   - `input: ["text", "image"]` is the model's declared capability;
//     this round AOS never sends image content, but `transformMessages`
//     reads this field so future image input requires no edits.
//   - `reasoning: true` powers `supportsXhigh` and the `streamSimple`
//     reasoning-effort mapping.

import type { Model } from "../types";

export const MODELS = {
  "chatgpt-plan": {
    "gpt-5-2": {
      id: "gpt-5-2",
      name: "GPT-5.2 (ChatGPT Plan)",
      api: "openai-responses",
      provider: "chatgpt-plan",
      // VERIFY: tentative endpoint pending ChatGPT plan auth confirmation.
      baseUrl: "https://chatgpt.com/backend-api/codex",
      reasoning: true,
      input: ["text", "image"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      contextWindow: 400_000,
      maxTokens: 16_384,
    },
  },
} as const satisfies Record<string, Record<string, Model<"openai-responses">>>;

export type KnownProvider = keyof typeof MODELS;
export type KnownModelId<P extends KnownProvider> = keyof (typeof MODELS)[P];
