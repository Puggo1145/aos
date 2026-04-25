// Capability predicates per guide §5.
//
// `supportsXhigh` and `supportsThinking` are id-regex driven (capability
// is a property of the specific weights, not the API protocol).
// `supportsVision` is fully derivable from `Model.input`.

import type { Api, Model } from "../types";

const XHIGH_PATTERNS: RegExp[] = [
  /gpt-5\.[2-5]/i,
  /opus-4[-.][67]/i,
];

const THINKING_PATTERNS: RegExp[] = [
  /gpt-5/i,
  /o[134]/i,
  /opus-4/i,
  /sonnet-4/i,
  /gemini-2\.5/i,
];

export function supportsXhigh<TApi extends Api>(model: Model<TApi>): boolean {
  return XHIGH_PATTERNS.some((p) => p.test(model.id));
}

export function supportsVision<TApi extends Api>(model: Model<TApi>): boolean {
  return model.input.includes("image");
}

export function supportsThinking<TApi extends Api>(model: Model<TApi>): boolean {
  if (model.reasoning) return true;
  return THINKING_PATTERNS.some((p) => p.test(model.id));
}
