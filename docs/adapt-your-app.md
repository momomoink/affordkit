# Add AffordKit to the app you already have

The quickest way: let your coding agent do it. AffordKit comes with an agent skill that knows the whole job. Install it, open
your project, and ask.

**Claude Code** (as a plugin from this repository):

```text
/plugin install affordkit --marketplace momomoink/affordkit
```

Then, in your project:

```text
Add AffordKit to this app.
```

or, for one thing at a time:

```text
Use AffordKit so the assistant can open a mail and reply to it.
```

<details>
<summary>Other ways to install the skill</summary>

- **Claude Code before 2.1.275:** add the marketplace first, then install:

  ```text
  /plugin marketplace add momomoink/affordkit
  /plugin install affordkit@affordkit
  ```

- **Claude Code, without the plugin:** copy [`skills/affordkit/`](../skills/affordkit/SKILL.md) to `~/.claude/skills/affordkit/`
  (all your projects) or to `.claude/skills/affordkit/` in one project.
- **claude.ai:** zip the `skills/affordkit/` folder and upload it in Settings (Features / Capabilities, under Skills). This needs a
  plan with code execution enabled.
- **Other agents:** the skill follows the open [Agent Skills](https://agentskills.io) format. Copy the folder to wherever your
  agent loads skills from.

In Claude Code the skill is `/affordkit:affordkit`; Claude also uses it by itself when you ask for AffordKit.

</details>

## What the agent does

**Adapting the whole app,** it:

1. looks at your project: the platform (Flutter or web), your shared components, router, long lists, and whether you already have
   an assistant and a channel to it;
2. installs AffordKit and sets it up;
3. lists what can be done on each screen and proposes what the agent may just do, what needs your yes first, and what stays
   yours alone (send, pay, publish). **It asks you before settling those.**
4. puts your controls into the AffordTree with clear names and stable keys, shared components first, without changing how the
   app looks or behaves;
5. turns long lists into containers, declares your pages, and adds app tools for what has no screen;
6. connects your agent, on your backend or in the app, over the channel you already have;
7. prints the tree for each screen, adds tests, and tells you what is covered and what isn't.

**Making one thing doable** ("let it reply to mail"), it walks that path in your app, covers only the controls it needs, and
tries the goal with your real model until it works, in several ways of asking.

## By hand

Rather do it yourself? The steps are the same; each platform's docs have the details:

| | Flutter | Web |
|---|---|---|
| Install and set up, put controls into the tree | [getting started](flutter/getting-started.md) | [getting started](js/getting-started.md) |
| What the agent may do | [what to expose](flutter/what-to-expose.md) | [what to expose](js/what-to-expose.md) |
| Connect your agent | [connecting an agent](flutter/connecting-an-agent.md) | [connecting an agent](js/connecting-an-agent.md) |
| When the user leaves the app | [handoffs](flutter/handoffs.md) | [handoffs](js/handoffs.md) |

The skill's own checklist, which works as well for a person: [`skills/affordkit/SKILL.md`](../skills/affordkit/SKILL.md).
