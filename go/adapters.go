package affordkit

// The agent's tools in the shapes the common agent stacks take — the Anthropic and OpenAI APIs, an MCP server, and plain runners
// for anything else (a loop of your own) — and their answers back in the shape each expects. No SDK is imported: these are plain
// structs that marshal to the JSON those APIs take (pass them as raw JSON, or copy the fields into the SDK's own types).
//
//	// Anthropic Messages API
//	body["tools"] = affordkit.AnthropicTools(ui.Tools())
//	for _, block := range res.Content {
//		if block.Type == "tool_use" && ui.Has(block.Name) {
//			results = append(results, affordkit.AnthropicResult(ctx, ui, affordkit.AnthropicToolUse{ID: block.ID, Name: block.Name, Input: block.Input}))
//		}
//	}
//
//	// MCP: the app's screen as an MCP server's tools
//	h := affordkit.MCPHandlers(ui)   // h.List(ctx) for tools/list, h.Call(ctx, req) for tools/call

import (
	"context"
	"encoding/json"
)

// AnthropicTool is a tool for the Anthropic Messages API.
type AnthropicTool struct {
	Name        string          `json:"name"`
	Description string          `json:"description"`
	InputSchema json.RawMessage `json:"input_schema"`
}

// AnthropicTools are the tools for the Anthropic Messages API.
func AnthropicTools(tools []AgentTool) []AnthropicTool {
	out := make([]AnthropicTool, len(tools))
	for i, t := range tools {
		out[i] = AnthropicTool{t.Name, t.Description, t.InputSchema}
	}
	return out
}

// AnthropicToolUse is a tool_use block the model sent. Input is its input: raw JSON (json.RawMessage, []byte, or a JSON string),
// or a decoded map.
type AnthropicToolUse struct {
	ID    string
	Name  string
	Input any
}

// AnthropicContent is a block of a tool_result's content: text, or an image.
type AnthropicContent struct {
	// Type is "text" or "image".
	Type string
	Text string
	// MediaType and Data are an image's (base64).
	MediaType string
	Data      string
}

// MarshalJSON writes {type: "text", text} or {type: "image", source: {type: "base64", media_type, data}}.
func (c AnthropicContent) MarshalJSON() ([]byte, error) {
	if c.Type == "image" {
		return marshalCompact(Entries[any]{{"type", "image"}, {"source", Entries[any]{{"type", "base64"}, {"media_type", c.MediaType}, {"data", c.Data}}}})
	}
	return marshalCompact(Entries[any]{{"type", c.Type}, {"text", c.Text}})
}

// AnthropicToolResult is a tool_result block. Content is a string, or []AnthropicContent when a picture goes with the text.
type AnthropicToolResult struct {
	Type      string `json:"type"`
	ToolUseID string `json:"tool_use_id"`
	Content   any    `json:"content"`
	IsError   bool   `json:"is_error,omitempty"`
}

// AnthropicResult runs a tool_use block: its tool_result block.
func AnthropicResult(ctx context.Context, remote *Remote, block AnthropicToolUse) AnthropicToolResult {
	a := remote.Handle(ctx, block.Name, asArgs(block.Input))
	// (a picture goes in the result beside the text)
	var content any = a.Text
	if len(a.Images) > 0 {
		blocks := []AnthropicContent{{Type: "text", Text: a.Text}}
		for _, i := range a.Images {
			blocks = append(blocks, AnthropicContent{Type: "image", MediaType: i.Mime, Data: i.Data})
		}
		content = blocks
	}
	return AnthropicToolResult{Type: "tool_result", ToolUseID: block.ID, Content: content, IsError: a.IsError}
}

// OpenAIFunction is a function's name, description and parameters (Chat Completions).
type OpenAIFunction struct {
	Name        string          `json:"name"`
	Description string          `json:"description"`
	Parameters  json.RawMessage `json:"parameters"`
}

// OpenAITool is a tool for OpenAI Chat Completions.
type OpenAITool struct {
	Type     string         `json:"type"`
	Function OpenAIFunction `json:"function"`
}

// OpenAITools are the tools for OpenAI Chat Completions.
func OpenAITools(tools []AgentTool) []OpenAITool {
	out := make([]OpenAITool, len(tools))
	for i, t := range tools {
		out[i] = OpenAITool{"function", OpenAIFunction{t.Name, t.Description, t.InputSchema}}
	}
	return out
}

// OpenAIToolCall is a tool call the model made (Chat Completions): its id, and its function's name and arguments (a JSON string).
type OpenAIToolCall struct {
	ID       string
	Function OpenAICalledFunction
}

// OpenAICalledFunction is the function a tool call names, and its arguments (a JSON string).
type OpenAICalledFunction struct {
	Name      string
	Arguments string
}

// OpenAIToolMessage is a tool message (Chat Completions).
type OpenAIToolMessage struct {
	Role       string `json:"role"`
	ToolCallID string `json:"tool_call_id"`
	Content    string `json:"content"`
}

// OpenAIResult runs a Chat Completions tool call: its tool message (text only there: a picture is left out, and the text says it
// is).
func OpenAIResult(ctx context.Context, remote *Remote, call OpenAIToolCall) OpenAIToolMessage {
	a := remote.Handle(ctx, call.Function.Name, parseArgs(call.Function.Arguments))
	return OpenAIToolMessage{"tool", call.ID, a.Text}
}

// OpenAIResponsesTool is a tool for the OpenAI Responses API.
type OpenAIResponsesTool struct {
	Type        string          `json:"type"`
	Name        string          `json:"name"`
	Description string          `json:"description"`
	Parameters  json.RawMessage `json:"parameters"`
}

// OpenAIResponsesTools are the tools for the OpenAI Responses API.
func OpenAIResponsesTools(tools []AgentTool) []OpenAIResponsesTool {
	out := make([]OpenAIResponsesTool, len(tools))
	for i, t := range tools {
		out[i] = OpenAIResponsesTool{"function", t.Name, t.Description, t.InputSchema}
	}
	return out
}

// OpenAIFunctionCall is a function_call item the model sent (Responses API); Arguments is a JSON string.
type OpenAIFunctionCall struct {
	CallID    string
	Name      string
	Arguments string
}

// OpenAIFunctionCallOutput is a function_call_output item (Responses API).
type OpenAIFunctionCallOutput struct {
	Type   string `json:"type"`
	CallID string `json:"call_id"`
	Output string `json:"output"`
}

// OpenAIResponsesResult runs a Responses API function_call: its function_call_output item.
func OpenAIResponsesResult(ctx context.Context, remote *Remote, call OpenAIFunctionCall) OpenAIFunctionCallOutput {
	a := remote.Handle(ctx, call.Name, parseArgs(call.Arguments))
	return OpenAIFunctionCallOutput{"function_call_output", call.CallID, a.Text}
}

// MCPTool is a tool in an MCP tools/list result.
type MCPTool struct {
	Name        string          `json:"name"`
	Description string          `json:"description"`
	InputSchema json.RawMessage `json:"inputSchema"`
}

// MCPToolList is an MCP tools/list result.
type MCPToolList struct {
	Tools []MCPTool `json:"tools"`
}

// MCPCallRequest is an MCP tools/call request.
type MCPCallRequest struct {
	Params MCPCallParams `json:"params"`
}

// MCPCallParams are a tools/call request's params.
type MCPCallParams struct {
	Name      string         `json:"name"`
	Arguments map[string]any `json:"arguments,omitempty"`
}

// MCPContent is a block of an MCP tools/call result: text, or an image.
type MCPContent struct {
	// Type is "text" or "image".
	Type     string
	Text     string
	Data     string
	MimeType string
}

// MarshalJSON writes {type: "text", text} or {type: "image", data, mimeType}.
func (c MCPContent) MarshalJSON() ([]byte, error) {
	if c.Type == "image" {
		return marshalCompact(Entries[any]{{"type", "image"}, {"data", c.Data}, {"mimeType", c.MimeType}})
	}
	return marshalCompact(Entries[any]{{"type", c.Type}, {"text", c.Text}})
}

// MCPCallResult is an MCP tools/call result.
type MCPCallResult struct {
	Content []MCPContent `json:"content"`
	IsError bool         `json:"isError,omitempty"`
}

// MCP is the handlers of an MCP server's tools/list and tools/call, serving the app's screen as its tools.
type MCP struct {
	remote *Remote
}

// MCPHandlers are MCP server handlers for tools/list and tools/call.
func MCPHandlers(remote *Remote) MCP {
	return MCP{remote}
}

// List answers tools/list.
func (m MCP) List(ctx context.Context) MCPToolList {
	tools := m.remote.Tools()
	out := MCPToolList{Tools: make([]MCPTool, len(tools))}
	for i, t := range tools {
		out.Tools[i] = MCPTool{t.Name, t.Description, t.InputSchema}
	}
	return out
}

// Call answers tools/call.
func (m MCP) Call(ctx context.Context, req MCPCallRequest) MCPCallResult {
	a := m.remote.Handle(ctx, req.Params.Name, req.Params.Arguments)
	content := []MCPContent{{Type: "text", Text: a.Text}}
	for _, i := range a.Images {
		content = append(content, MCPContent{Type: "image", Data: i.Data, MimeType: i.Mime})
	}
	return MCPCallResult{Content: content, IsError: a.IsError}
}

// Runner is a tool with a function that runs it (for a loop of your own, or a framework's tool type): its answer, text and all.
type Runner struct {
	AgentTool
	Run func(ctx context.Context, input map[string]any) ToolAnswer `json:"-"`
}

// Runners are the tools, each with a function that runs it.
func Runners(remote *Remote) []Runner {
	tools := remote.Tools()
	out := make([]Runner, len(tools))
	for i, t := range tools {
		name := t.Name
		out[i] = Runner{t, func(ctx context.Context, input map[string]any) ToolAnswer { return remote.Handle(ctx, name, input) }}
	}
	return out
}

// asArgs is a tool's input as an object: decoded from raw JSON when it is that, {} when it is not an object.
func asArgs(input any) map[string]any {
	switch x := input.(type) {
	case nil:
		return map[string]any{}
	case map[string]any:
		return x
	case json.RawMessage:
		return parseArgs(string(x))
	case []byte:
		return parseArgs(string(x))
	case string:
		return parseArgs(x)
	}
	b, err := json.Marshal(input)
	if err != nil {
		return map[string]any{}
	}
	return parseArgs(string(b))
}

// parseArgs is a JSON string of arguments as an object ({} when it is empty, not JSON, or not an object).
func parseArgs(s string) map[string]any {
	if s == "" {
		s = "{}"
	}
	var m map[string]any
	if json.Unmarshal([]byte(s), &m) != nil || m == nil {
		return map[string]any{}
	}
	return m
}
