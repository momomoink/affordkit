/**
 * The agent's tools in the shapes the common agent stacks take — the Anthropic and OpenAI APIs, an MCP server, and plain runners for
 * anything else (LangChain, the AI SDK, a loop of your own) — and their answers back in the shape each expects. No SDK is imported:
 * these are the plain objects those SDKs take.
 *
 *   // Anthropic Messages API
 *   const res = await client.messages.create({ ..., tools: anthropicTools(ui.tools()) });
 *   for (const block of res.content) if (block.type === 'tool_use' && ui.has(block.name)) results.push(await anthropicResult(ui, block));
 *
 *   // MCP (@modelcontextprotocol/sdk): the app's screen as an MCP server's tools
 *   const h = mcpHandlers(ui);
 *   server.setRequestHandler(ListToolsRequestSchema, h.list);
 *   server.setRequestHandler(CallToolRequestSchema, h.call);
 */

import type { AgentTool } from './agent.js';
import type { AffordRemote, ToolAnswer } from './remote.js';

/** Anthropic Messages API tools. */
export function anthropicTools(tools: AgentTool[]): { name: string; description: string; input_schema: AgentTool['inputSchema'] }[] {
  return tools.map((t) => ({ name: t.name, description: t.description, input_schema: t.inputSchema }));
}

/** A tool_use block run: its tool_result block. */
export async function anthropicResult(
  remote: AffordRemote,
  block: { id: string; name: string; input: unknown },
): Promise<{ type: 'tool_result'; tool_use_id: string; content: string | AnthropicContent[]; is_error?: boolean }> {
  const a = await remote.handle(block.name, asArgs(block.input));
  // (a picture goes in the result beside the text)
  const content = a.images?.length
    ? [{ type: 'text' as const, text: a.text }, ...a.images.map((i) => ({ type: 'image' as const, source: { type: 'base64' as const, media_type: i.mime, data: i.data } }))]
    : a.text;
  return { type: 'tool_result', tool_use_id: block.id, content, ...(a.isError ? { is_error: true } : {}) };
}

type AnthropicContent = { type: 'text'; text: string } | { type: 'image'; source: { type: 'base64'; media_type: string; data: string } };

/** OpenAI Chat Completions tools. */
export function openaiTools(tools: AgentTool[]): { type: 'function'; function: { name: string; description: string; parameters: AgentTool['inputSchema'] } }[] {
  return tools.map((t) => ({ type: 'function', function: { name: t.name, description: t.description, parameters: t.inputSchema } }));
}

/** A Chat Completions tool call run: its tool message (text only there: a picture is left out, and the text says it is). */
export async function openaiResult(remote: AffordRemote, call: { id: string; function: { name: string; arguments: string } }): Promise<{ role: 'tool'; tool_call_id: string; content: string }> {
  const a = await remote.handle(call.function.name, parseArgs(call.function.arguments));
  return { role: 'tool', tool_call_id: call.id, content: a.text };
}

/** OpenAI Responses API tools. */
export function openaiResponsesTools(tools: AgentTool[]): { type: 'function'; name: string; description: string; parameters: AgentTool['inputSchema'] }[] {
  return tools.map((t) => ({ type: 'function', name: t.name, description: t.description, parameters: t.inputSchema }));
}

/** A Responses API function_call run: its function_call_output item. */
export async function openaiResponsesResult(remote: AffordRemote, call: { call_id: string; name: string; arguments: string }): Promise<{ type: 'function_call_output'; call_id: string; output: string }> {
  const a = await remote.handle(call.name, parseArgs(call.arguments));
  return { type: 'function_call_output', call_id: call.call_id, output: a.text };
}

/** MCP server handlers for tools/list and tools/call. */
export function mcpHandlers(remote: AffordRemote): {
  list: () => Promise<{ tools: { name: string; description: string; inputSchema: AgentTool['inputSchema'] }[] }>;
  call: (request: { params: { name: string; arguments?: Record<string, unknown> } }) => Promise<{ content: ({ type: 'text'; text: string } | { type: 'image'; data: string; mimeType: string })[]; isError?: boolean }>;
} {
  return {
    list: async () => ({ tools: remote.tools().map((t) => ({ name: t.name, description: t.description, inputSchema: t.inputSchema })) }),
    call: async (request) => {
      const a = await remote.handle(request.params.name, request.params.arguments ?? {});
      return { content: [{ type: 'text', text: a.text }, ...(a.images ?? []).map((i) => ({ type: 'image' as const, data: i.data, mimeType: i.mime }))], ...(a.isError ? { isError: true } : {}) };
    },
  };
}

/** Each tool with a run function (for LangChain, the AI SDK, or a loop of your own): its answer, text and all. */
export function runners(remote: AffordRemote): (AgentTool & { run: (input: Record<string, unknown>) => Promise<ToolAnswer> })[] {
  return remote.tools().map((t) => ({ ...t, run: (input) => remote.handle(t.name, input) }));
}

function asArgs(input: unknown): Record<string, unknown> {
  return input && typeof input === 'object' ? (input as Record<string, unknown>) : {};
}

function parseArgs(json: string): Record<string, unknown> {
  try {
    return asArgs(JSON.parse(json || '{}'));
  } catch {
    return {};
  }
}
