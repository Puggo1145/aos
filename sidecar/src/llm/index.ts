// Public surface of the LLM subpackage. The agent loop must consume
// only these exports — direct imports of `./providers/*`, `./auth/*`,
// `./models/catalog`, or `./utils/*` from the agent layer are
// disallowed (see docs/designs/llm-provider.md "包边界").

import { registerBuiltins } from "./providers/register-builtins";

export { stream, streamSimple } from "./stream";
export { getModel, getProviders, getModels, modelsAreEqual } from "./models/registry";
export { isContextOverflow } from "./utils/overflow";
export { validateToolCall, validateToolArguments } from "./utils/validation";
export { calculateCost } from "./models/cost";
export { transformMessages } from "./providers/transform-messages";
export { registerApiProvider, unregisterApiProviders } from "./api-registry";

export type {
  Api,
  Provider,
  Message,
  UserMessage,
  AssistantMessage,
  ToolResultMessage,
  TextContent,
  ThinkingContent,
  ImageContent,
  ToolCall,
  Tool,
  JSONSchema,
  Context,
  Model,
  ModelCost,
  Usage,
  UsageCost,
  StopReason,
  StreamOptions,
  SimpleStreamOptions,
  ProviderStreamOptions,
  ThinkingLevel,
  AssistantMessageEvent,
  StreamFunction,
  SimpleStreamFunction,
  ApiProviderEntry,
} from "./types";

// Side effect: register built-in providers exactly once on first import.
registerBuiltins();
