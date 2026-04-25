// ChatGPT plan OAuth (PKCE) provider + login CLI.
//
// VERIFY: the endpoint URLs, client_id, and scope strings below are
// PROVISIONAL. The PKCE shape, loopback flow, token storage layout,
// refresh policy, and CLI surface are all stable contracts; only these
// constants need to be revised once the real ChatGPT plan auth endpoint
// is confirmed (see docs/designs/llm-provider.md "风险" section).

import { createHash, randomBytes } from "node:crypto";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";

import type {
  AuthorizeOptions,
  ExchangeOptions,
  OAuthProviderInterface,
  TokenSet,
} from "./types";
import { writeChatGPTPlanToken, readChatGPTPlanToken } from "./storage";

// VERIFY: must be confirmed against ChatGPT plan auth endpoint.
export const CHATGPT_PLAN_AUTHORIZE_URL = "https://auth.openai.com/oauth/authorize";
// VERIFY: must be confirmed against ChatGPT plan auth endpoint.
export const CHATGPT_PLAN_TOKEN_URL = "https://auth.openai.com/oauth/token";
// VERIFY: must be set before login can succeed.
export const CHATGPT_PLAN_CLIENT_ID = "TBD";
// VERIFY: tentative scope list.
export const CHATGPT_PLAN_SCOPES = ["openid", "profile", "email"];

// ---------------------------------------------------------------------------
// PKCE primitives
// ---------------------------------------------------------------------------

export function base64url(bytes: Buffer | Uint8Array): string {
  return Buffer.from(bytes).toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function generateCodeVerifier(): string {
  return base64url(randomBytes(32));
}

export function computeCodeChallenge(codeVerifier: string): string {
  return base64url(createHash("sha256").update(codeVerifier).digest());
}

export function generateState(): string {
  return base64url(randomBytes(16));
}

// ---------------------------------------------------------------------------
// Provider implementation
// ---------------------------------------------------------------------------

export const chatgptPlanOAuthProvider: OAuthProviderInterface = {
  name: "chatgpt-plan",

  buildAuthorizeUrl(opts: AuthorizeOptions): string {
    const challenge = computeCodeChallenge(opts.codeVerifier);
    const params = new URLSearchParams({
      response_type: "code",
      client_id: CHATGPT_PLAN_CLIENT_ID,
      redirect_uri: opts.redirectUri,
      scope: CHATGPT_PLAN_SCOPES.join(" "),
      state: opts.state,
      code_challenge: challenge,
      code_challenge_method: "S256",
    });
    return `${CHATGPT_PLAN_AUTHORIZE_URL}?${params.toString()}`;
  },

  async exchangeCode(opts: ExchangeOptions): Promise<TokenSet> {
    const body = new URLSearchParams({
      grant_type: "authorization_code",
      code: opts.code,
      redirect_uri: opts.redirectUri,
      client_id: CHATGPT_PLAN_CLIENT_ID,
      code_verifier: opts.codeVerifier,
    });
    const res = await fetch(CHATGPT_PLAN_TOKEN_URL, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded", accept: "application/json" },
      body: body.toString(),
    });
    if (!res.ok) {
      const text = await res.text().catch(() => "");
      throw new Error(`token exchange failed: ${res.status} ${text}`);
    }
    const json = (await res.json()) as Record<string, unknown>;
    return parseTokenResponse(json);
  },

  async refresh(refreshToken: string): Promise<TokenSet> {
    const body = new URLSearchParams({
      grant_type: "refresh_token",
      refresh_token: refreshToken,
      client_id: CHATGPT_PLAN_CLIENT_ID,
    });
    const res = await fetch(CHATGPT_PLAN_TOKEN_URL, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded", accept: "application/json" },
      body: body.toString(),
    });
    if (!res.ok) {
      const text = await res.text().catch(() => "");
      throw new Error(`token refresh failed: ${res.status} ${text}`);
    }
    const json = (await res.json()) as Record<string, unknown>;
    return parseTokenResponse(json);
  },
};

function parseTokenResponse(json: Record<string, unknown>): TokenSet {
  const accessToken = json["access_token"];
  const refreshToken = json["refresh_token"];
  const expiresIn = json["expires_in"];
  const accountId = json["account_id"] ?? json["accountId"];
  if (typeof accessToken !== "string" || typeof refreshToken !== "string" || typeof expiresIn !== "number") {
    throw new Error(`malformed token response: ${JSON.stringify(json)}`);
  }
  return {
    accessToken,
    refreshToken,
    expiresIn,
    accountId: typeof accountId === "string" ? accountId : undefined,
  };
}

// ---------------------------------------------------------------------------
// Runtime token read / refresh (used by openai-responses provider)
// ---------------------------------------------------------------------------

const REFRESH_LEAD_MS = 60_000;
let refreshInflight: Promise<{ accessToken: string; refreshToken: string; expiresAt: number; accountId?: string }> | null = null;

/// Read the persisted token; if it is within `REFRESH_LEAD_MS` of
/// expiry, transparently refresh and rewrite the file before returning.
/// Concurrent callers are deduplicated via an in-process promise cache.
export async function readChatGPTToken(): Promise<{ accessToken: string; refreshToken: string; expiresAt: number; accountId?: string }> {
  const stored = readChatGPTPlanToken();
  if (!stored) throw new Error("ChatGPT 订阅未授权");
  if (stored.expiresAt - Date.now() > REFRESH_LEAD_MS) return stored;
  if (refreshInflight) return refreshInflight;
  refreshInflight = (async () => {
    try {
      const next = await chatgptPlanOAuthProvider.refresh(stored.refreshToken);
      const record = {
        accessToken: next.accessToken,
        refreshToken: next.refreshToken,
        expiresAt: Date.now() + next.expiresIn * 1000,
        accountId: next.accountId ?? stored.accountId,
      };
      writeChatGPTPlanToken(record);
      return record;
    } catch (err) {
      throw new Error("ChatGPT 订阅授权已失效，请重新登录");
    } finally {
      refreshInflight = null;
    }
  })();
  return refreshInflight;
}

// ---------------------------------------------------------------------------
// Login CLI
// ---------------------------------------------------------------------------

export async function runLoginCLI(): Promise<void> {
  if (CHATGPT_PLAN_CLIENT_ID === "TBD") {
    process.stderr.write("CHATGPT_PLAN_CLIENT_ID is not configured. Set the constant in chatgpt-plan.ts before running login.\n");
    process.exit(2);
  }
  const codeVerifier = generateCodeVerifier();
  const state = generateState();

  const { port, codePromise, close } = await startCallbackServer(state);
  const redirectUri = `http://127.0.0.1:${port}/callback`;
  const authorizeUrl = chatgptPlanOAuthProvider.buildAuthorizeUrl({ codeVerifier, redirectUri, state });

  process.stdout.write(`\nOpen the following URL in your browser to log in:\n\n  ${authorizeUrl}\n\nWaiting for callback on ${redirectUri} ...\n`);

  try {
    const code = await codePromise;
    const tokens = await chatgptPlanOAuthProvider.exchangeCode({ code, codeVerifier, redirectUri });
    writeChatGPTPlanToken({
      accessToken: tokens.accessToken,
      refreshToken: tokens.refreshToken,
      expiresAt: Date.now() + tokens.expiresIn * 1000,
      accountId: tokens.accountId,
    });
    process.stdout.write("Login successful. Token saved.\n");
  } finally {
    close();
  }
}

interface CallbackHandle {
  port: number;
  codePromise: Promise<string>;
  close: () => void;
}

function startCallbackServer(expectedState: string): Promise<CallbackHandle> {
  return new Promise((resolveStart, rejectStart) => {
    let resolveCode: (code: string) => void;
    let rejectCode: (err: Error) => void;
    const codePromise = new Promise<string>((res, rej) => {
      resolveCode = res;
      rejectCode = rej;
    });
    const server = createServer((req, res) => {
      try {
        if (!req.url) {
          res.writeHead(400).end("Bad request");
          return;
        }
        const url = new URL(req.url, "http://127.0.0.1");
        if (url.pathname !== "/callback") {
          res.writeHead(404).end("Not found");
          return;
        }
        const code = url.searchParams.get("code");
        const state = url.searchParams.get("state");
        if (!code || !state) {
          res.writeHead(400).end("Missing code or state");
          rejectCode(new Error("OAuth callback missing code or state"));
          return;
        }
        if (state !== expectedState) {
          res.writeHead(400).end("State mismatch");
          rejectCode(new Error("OAuth state mismatch"));
          return;
        }
        res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
        res.end("<html><body><p>Login successful, you can close this tab.</p></body></html>");
        resolveCode(code);
      } catch (err) {
        rejectCode(err instanceof Error ? err : new Error(String(err)));
      }
    });
    server.once("error", (err) => rejectStart(err));
    server.listen(0, "127.0.0.1", () => {
      const addr = server.address() as AddressInfo;
      resolveStart({
        port: addr.port,
        codePromise,
        close: () => server.close(),
      });
    });
  });
}

// ---------------------------------------------------------------------------
// CLI entry
// ---------------------------------------------------------------------------

// `import.meta.main` is Bun-specific; this file is intended to be run as
// `bun run src/llm/auth/oauth/chatgpt-plan.ts`.
if ((import.meta as unknown as { main?: boolean }).main) {
  runLoginCLI().catch((err) => {
    process.stderr.write(`login failed: ${err instanceof Error ? err.message : String(err)}\n`);
    process.exit(1);
  });
}
