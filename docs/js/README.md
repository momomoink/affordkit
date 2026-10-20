# AffordKit for JavaScript: documentation

AffordKit lets an AI agent see and use your web app's UI the way a person does: it reads the page as a small tree of controls,
then presses, types, scrolls and navigates through calls your app runs under its own rules.

| Read | When |
|---|---|
| [Concepts](concepts.md) | First. The tree, nodes and ops, policies, containers, pages, app tools. |
| [Getting started](getting-started.md) | Adding AffordKit to a web app: plain DOM, React, Vue, Svelte, anything else. |
| [What to expose](what-to-expose.md) | Deciding what the agent may do, what needs the user's yes, and what it must never touch. |
| [Connecting an agent](connecting-an-agent.md) | Wiring the page to the model: transports, `AffordRemote`, answers, error codes, the Anthropic / OpenAI / MCP shapes. |
| [Handoffs](handoffs.md) | When the user has left the app: the agent leaves a message and the calls that take them to its work. |
| [Protocol](../protocol.md) | The JSON, for writing your own agent side. |

There is also an [agent skill](https://github.com/momomoink/affordkit/blob/main/skills/affordkit/SKILL.md) that walks a coding
agent through adding AffordKit to an existing project. The [repository README](https://github.com/momomoink/affordkit#let-your-coding-agent-add-it)
says how to install it.
