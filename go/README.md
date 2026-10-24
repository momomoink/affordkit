# AffordKit for Go

The agent's side of [AffordKit](https://github.com/momomoink/affordkit), for a Go backend: the app's screen (sent by its
AffordKit, Flutter or web) becomes tools for your model, and the model's calls run on it. No dependencies beyond the standard
library; it does what the TypeScript `AffordRemote` does, answer for answer (checked by `conformance/remote.json`).

```sh
go get github.com/momomoink/affordkit/go
```

```go
import affordkit "github.com/momomoink/affordkit/go"
```

## Connect an agent

The app answers the agent's requests with `kit.answer(request)` (JSON in, JSON out), over the channel you already have. Where
the model runs, `Remote` gives it its tools and runs them:

```go
ui := affordkit.NewRemote(affordkit.RemoteOptions{
	// Send the request to the app and decode its answer (a UiAnswer is the JSON kit.answer gives)
	Send: func(ctx context.Context, req affordkit.UiRequest) (affordkit.UiAnswer, error) {
		return askTheApp(ctx, req)
	},
})
ui.Seen(screenSentWithTheMessage) // optional: what the user was looking at

// Anthropic Messages API: the tools go in the request as they are (they marshal to its JSON)
body := map[string]any{"model": model, "max_tokens": 4096, "messages": messages, "tools": affordkit.AnthropicTools(ui.Tools())}
// ... and each tool_use block the model sends back gets its tool_result
for _, block := range res.Content {
	if block.Type == "tool_use" && ui.Has(block.Name) {
		results = append(results, affordkit.AnthropicResult(ctx, ui, affordkit.AnthropicToolUse{ID: block.ID, Name: block.Name, Input: block.Input}))
	}
}

// OpenAI Chat Completions
body["tools"] = affordkit.OpenAITools(ui.Tools())
for _, call := range msg.ToolCalls {
	messages = append(messages, affordkit.OpenAIResult(ctx, ui, affordkit.OpenAIToolCall{
		ID: call.ID, Function: affordkit.OpenAICalledFunction{Name: call.Function.Name, Arguments: call.Function.Arguments},
	}))
}
```

No SDK is imported: the adapters return plain structs that marshal to each API's JSON, so they go into a raw request body as
they are, or field by field into an SDK's own types. `Input` takes the tool_use input as raw JSON (`json.RawMessage`) or decoded.

After each act the model gets what changed on screen, not the whole tree again:

```
Done.

The screen changed:
Now at /reply/7 (was /message/7) — can go back.
+ [n12 key=compose.body] textbox "Body" — read, write, append, clear
+ [n13 key=compose.send] button "Send" — press(deny)
- [thread.reply] button "Reply"
```

Other stacks: `OpenAIResponsesTools` / `OpenAIResponsesResult` (Responses API), `MCPHandlers` (`List` and `Call`: serve the
app's screen as an MCP server's tools), `Runners` (each tool with a `Run` func, for a loop of your own). Or call
`ui.Handle(ctx, name, input)` yourself: it never returns an error — a failure is a `ToolAnswer` with `IsError` and a `Code`.

When the user has left the app (`Present` returns false), the screen tools answer `away`, and with `OnHandoff` the agent can
leave them a handoff (`ui_handoff`) that the app runs when they come back: see
[Handoffs](https://github.com/momomoink/affordkit/blob/main/docs/js/handoffs.md). A failed call carries a code: `not_found`,
`no_op`, `bad_args`, `denied`, `needs_confirm`, `declined`, `disabled`, `unreachable`, `timeout`, `unavailable`, `away`,
`expired`, `failed`. Return an `*affordkit.AffordError{Code, Message}` from `Send` or `OnHandoff` to say which; find one with
`errors.As`.

```go
ui := affordkit.NewRemote(affordkit.RemoteOptions{
	Send:    send,
	Timeout: 20 * time.Second,           // default 45 s, then code timeout
	Screen:  affordkit.ScreenWhole,      // the whole tree after each act (default: what changed)
	Present: func() bool { return appInForeground(userID) },
	OnHandoff: func(ctx context.Context, h affordkit.Handoff) (string, error) {
		return "notification sent", push(ctx, userID, h)
	},
})
```

## Tests

No Go installed? Run them in Docker, from the repository root (they read `../conformance/remote.json`):

```sh
docker run --rm -v "$PWD:/repo" -w /repo/go golang:1.23.4 sh -c "gofmt -l . && go vet ./... && go test ./..."
```

In Git Bash on Windows, prefix it with `MSYS_NO_PATHCONV=1` and mount `"$(cygpath -w "$PWD"):/repo"`.
