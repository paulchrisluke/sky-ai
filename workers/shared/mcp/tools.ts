import type { CloudflareAuthEnv } from '../betterAuth';
import type { McpAuthContext } from './auth';

export interface SearchResultLike {
  message_id: string;
  thread_id: string | null;
  date: string | null;
  from: string;
  subject: string;
  excerpt: string;
  score: number;
  chunk_id: string;
}

/** Worker-provided capabilities the MCP tools depend on (avoids importing the worker). */
export interface McpToolDeps {
  semanticSearch(
    workspaceId: string,
    accountId: string,
    query: string,
    k: number,
  ): Promise<SearchResultLike[]>;
}

export interface McpToolContext extends McpAuthContext {
  env: CloudflareAuthEnv;
  deps: McpToolDeps;
}

export interface McpJsonSchema {
  type: 'object';
  properties?: Record<string, unknown>;
  required?: string[];
  additionalProperties?: boolean;
}

export interface McpTool {
  name: string;
  description: string;
  inputSchema: McpJsonSchema;
  handler(ctx: McpToolContext, args: Record<string, unknown>): Promise<unknown>;
}

// Read-only tools exposing the synced personal data. Populated below.
export const MCP_TOOLS: McpTool[] = [];
