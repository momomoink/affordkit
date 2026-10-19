# AffordKit documentation

AffordKit lets an AI agent see and use your app's UI the way a person does: it reads the screen as a small tree of controls,
then presses, types, scrolls and navigates through calls your app runs under its own rules.

| Read | When |
|---|---|
| [Concepts](concepts.md) | First. The tree, nodes and ops, policies, containers, pages, app tools. |
| [Getting started: web](getting-started-web.md) | Adding AffordKit to a web app (plain DOM, React, Vue, anything else). |
| [Getting started: Flutter](getting-started-flutter.md) | Adding AffordKit to a Flutter app. |
| [What to expose](what-to-expose.md) | Deciding what the agent may do, what needs the user's yes, and what it must never touch. |
| [Connecting an agent](connecting-an-agent.md) | Wiring the kit to the model: transports, the agent's tools, answers, errors, the Anthropic / OpenAI / MCP shapes. |
| [Protocol](protocol.md) | The JSON both runtimes speak, for writing your own agent side or a new runtime. |

There is also an [agent skill](../skills/affordkit/SKILL.md) that walks a coding agent through adding AffordKit to an existing
project. The repository README says how to install it.
