import {
  asMcpError,
  mcpFailure,
  mcpProtocolError,
  mcpSuccess,
  MCP_ERROR,
  MCP_PROTOCOL_VERSION,
  readMcpRequest,
} from './protocol';
import { McpAuthError, requireMcpUser } from './auth';
import { MCP_TOOLS, type McpToolDeps } from './tools';
import { authBaseUrl, SKY_MCP_SCOPE, type CloudflareAuthEnv } from '../betterAuth';

const SERVER_INFO = { name: 'sky-ai-mcp', version: '1' };

const INSTRUCTIONS = `Sky AI — your personal data assistant. This connection exposes your synced
Apple Mail, Calendar, iMessage, and extracted entities.

Use search_messages for natural-language questions about emails and messages. Use
list_calendar_events to see upcoming meetings, list_imessages for recent texts, and
list_entities for action items / financial items extracted from mail. get_briefing_data
returns a combined snapshot (upcoming events + recent messages + open items) — ideal for
questions like "who should I call tomorrow". All tools are read-only and scoped to your
own workspace.`;

const DISCOVER_VERSIONS = ['2026-07-28', '2025-11-25', '2025-03-26', '2024-11-05'];

/** POST /mcp handler — stateless JSON-RPC over HTTP. */
export async function handleMcpRequest(
  request: Request,
  env: CloudflareAuthEnv,
  deps: McpToolDeps,
): Promise<Response> {
  const baseUrl = authBaseUrl(env);
  const challenge = oauthChallenge(baseUrl);
  let requestId: string | number | null | undefined;
  let requestMethod: string | undefined;

  try {
    const hasBearer = request.headers.get('authorization')?.startsWith('Bearer ') ?? false;
    const hasCookie = Boolean(request.headers.get('cookie'));

    const bodyText = await request.text();
    let body: unknown = null;
    if (bodyText) {
      try {
        body = JSON.parse(bodyText);
      } catch {
        throw mcpProtocolError(MCP_ERROR.parse, 'Invalid JSON body.');
      }
    }

    // Pre-parse 401 so OAuth clients can discover the authorization server.
    if (!hasBearer && !hasCookie) {
      const raw = body && typeof body === 'object' && !Array.isArray(body) ? (body as Record<string, unknown>) : null;
      requestId = (raw?.id as string | number | undefined) ?? null;
      requestMethod = raw?.method as string | undefined;
      const payload =
        requestMethod === 'tools/call'
          ? mcpSuccess(requestId ?? null, mcpAuthRequiredResult(challenge))
          : mcpFailure(requestId ?? null, { code: MCP_ERROR.invalidRequest, message: 'Authentication required.' });
      return rpcResponse(payload, 401, challenge);
    }

    // ChatGPT sends empty-body health probes — answer 200 with no content.
    if (!body || (typeof body === 'object' && Object.keys(body as object).length === 0)) {
      return new Response('', { status: 200 });
    }

    const rpc = readMcpRequest(request.headers, body);
    requestId = rpc.id;
    requestMethod = rpc.method;

    switch (rpc.method) {
      case 'initialize': {
        await requireMcpUser(request, env);
        return rpcResponse(
          mcpSuccess(rpc.id, {
            protocolVersion: MCP_PROTOCOL_VERSION,
            capabilities: { tools: {}, resources: {}, prompts: {} },
            serverInfo: SERVER_INFO,
            instructions: INSTRUCTIONS,
          }),
        );
      }
      case 'notifications/initialized':
        return new Response('', { status: 202 });
      case 'ping':
        return rpcResponse(mcpSuccess(rpc.id, {}));
      case 'resources/list':
        await requireMcpUser(request, env);
        return rpcResponse(mcpSuccess(rpc.id, { resources: [] }));
      case 'resources/templates/list':
        await requireMcpUser(request, env);
        return rpcResponse(mcpSuccess(rpc.id, { resourceTemplates: [] }));
      case 'prompts/list':
        await requireMcpUser(request, env);
        return rpcResponse(mcpSuccess(rpc.id, { prompts: [] }));
      case 'server/discover':
        await requireMcpUser(request, env);
        return rpcResponse(
          mcpSuccess(rpc.id, {
            supportedVersions: DISCOVER_VERSIONS,
            capabilities: { tools: {} },
            serverInfo: SERVER_INFO,
            instructions: INSTRUCTIONS,
          }),
        );
      case 'tools/list': {
        await requireMcpUser(request, env);
        const tools = MCP_TOOLS.map((tool) => ({
          name: tool.name,
          description: tool.description,
          inputSchema: tool.inputSchema,
          annotations: { readOnlyHint: true },
          securitySchemes: [{ type: 'oauth2', scopes: [SKY_MCP_SCOPE] }],
        }));
        return rpcResponse(mcpSuccess(rpc.id, { tools }));
      }
      case 'tools/call': {
        const ctx = await requireMcpUser(request, env);
        const toolName = typeof rpc.params?.name === 'string' ? rpc.params.name : '';
        const tool = MCP_TOOLS.find((t) => t.name === toolName);
        if (!tool) throw mcpProtocolError(MCP_ERROR.methodNotFound, `Unknown tool: ${toolName}`);

        const rawArgs =
          rpc.params?.arguments && typeof rpc.params.arguments === 'object' && !Array.isArray(rpc.params.arguments)
            ? (rpc.params.arguments as Record<string, unknown>)
            : {};

        const result = await tool.handler({ ...ctx, env, deps }, rawArgs);
        return rpcResponse(
          mcpSuccess(rpc.id, {
            isError: false,
            structuredContent: result,
            content: [{ type: 'text', text: JSON.stringify(result, null, 2) }],
          }),
        );
      }
      default:
        throw mcpProtocolError(MCP_ERROR.methodNotFound, `Unsupported MCP method: ${rpc.method}`);
    }
  } catch (error) {
    if (error instanceof McpAuthError) {
      const payload =
        requestMethod === 'tools/call'
          ? mcpSuccess(requestId ?? null, mcpAuthRequiredResult(challenge))
          : mcpFailure(requestId ?? null, { code: MCP_ERROR.invalidRequest, message: error.message });
      return rpcResponse(payload, error.statusCode, error.challenge ? challenge : undefined);
    }

    const mcpError = asMcpError(error);
    const status =
      mcpError.code === MCP_ERROR.methodNotFound
        ? 404
        : mcpError.code === MCP_ERROR.invalidRequest ||
            mcpError.code === MCP_ERROR.invalidParams ||
            mcpError.code === MCP_ERROR.parse
          ? 400
          : 500;
    console.error('[MCP]', status, mcpError.code, mcpError.message, 'method:', requestMethod ?? null);
    return rpcResponse(mcpFailure(requestId ?? null, mcpError), status);
  }
}

function oauthChallenge(baseUrl: string, error = 'invalid_token', description = 'Connect Sky AI to continue.'): string {
  return `Bearer resource_metadata="${baseUrl}/.well-known/oauth-protected-resource", error="${error}", error_description="${description}"`;
}

function mcpAuthRequiredResult(challenge: string) {
  return {
    isError: true,
    content: [{ type: 'text', text: 'Authentication required: connect Sky AI to continue.' }],
    _meta: { 'mcp/www_authenticate': [challenge] },
  };
}

function rpcResponse(payload: unknown, status = 200, challenge?: string): Response {
  const headers: Record<string, string> = { 'content-type': 'application/json' };
  if (challenge) headers['WWW-Authenticate'] = challenge;
  return new Response(JSON.stringify(payload), { status, headers });
}
