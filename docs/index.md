---
hide:
  - navigation
---

# AffordKit

**AffordKit is a frontend library: it lets an AI agent on your backend use your app's UI the way a person would.** Open that
mail, press Reply, type the answer; the user watches it happen, on their own screen.

![Your app's screen goes to AffordKit, which gives the agent a small tree of its controls (the AffordTree); the agent answers with calls, which your app runs under your rules.](assets/concept.svg#only-light)
![Your app's screen goes to AffordKit, which gives the agent a small tree of its controls (the AffordTree); the agent answers with calls, which your app runs under your rules.](assets/concept-dark.svg#only-dark)

!!! tip "Already have an app? Add AffordKit with ease"

    Install the skill in your coding agent and ask it to "add AffordKit to this app": it does the whole job, and asks you what the
    agent may do. [How it works →](adapt-your-app.md)

    ```text
    /plugin install affordkit --marketplace momomoink/affordkit
    ```

<div class="grid cards" markdown>

-   **Flutter**

    ---

    `flutter pub add affordkit`, then put your widgets into the tree.

    [:octicons-arrow-right-24: Flutter](flutter/README.md)

-   **Web**

    ---

    `npm install affordkit`, for any framework, and the agent's side on your server.

    [:octicons-arrow-right-24: JavaScript / TypeScript](js/README.md)

-   **Already have an app**

    ---

    Let your coding agent adapt it, or do it by hand, step by step.

    [:octicons-arrow-right-24: Add AffordKit to your app](adapt-your-app.md)

-   **The protocol**

    ---

    The JSON the app and the agent speak, for an agent side of your own.

    [:octicons-arrow-right-24: Protocol](protocol.md)

</div>

## Why

- **Not pixels.** The agent doesn't read screenshots and guess where to click. It gets the screen as a few lines of text, each
  control with what it is, what it shows and what can be done to it; fast, cheap, and it doesn't miss.
- **Not a second API.** What the agent does goes through the same buttons, fields and pages the user has, with the same checks.
  There is nothing extra to build and keep in step.
- **The user stays in charge.** You decide what it may just do, what needs the user's yes first, and what is theirs alone (send,
  pay). They see each step, can stop it, and can keep using the app meanwhile: the agent is told what they did.

## How it works

![What AffordKit gives you (solid) and what is yours (dashed): in your app, AffordKit builds the AffordTree and answers requests; on your server, AffordRemote gives your agent the screen as tools; your channel carries UiRequest and UiAnswer between them.](assets/how-it-works.svg#only-light)
![What AffordKit gives you (solid) and what is yours (dashed): in your app, AffordKit builds the AffordTree and answers requests; on your server, AffordRemote gives your agent the screen as tools; your channel carries UiRequest and UiAnswer between them.](assets/how-it-works-dark.svg#only-dark)

AffordKit is the two solid parts. In the app, the **kit** builds the AffordTree from your UI and runs what the agent asks. On your
server, **`AffordRemote`** turns the screen into tools for your agent, in the shape its API takes. The agent itself is yours (your
model, loop and prompt, or an agent like Claude Code), and so is the channel between app and server; AffordKit doesn't run or
host either. That channel carries two messages: a `UiRequest` (look, or calls) and a `UiAnswer` (the tree after, the results, and
what the user did meanwhile). One round:

**1. The screen becomes an AffordTree.** Only the controls that mean something, never their content until it is read:

```text
Route: /message/42 — can go back
[w4 key=thread.reply] button "Reply" — press
[w7 key=thread.body] text "Message" — read
[w9 key=compose.send] button "Send" — press(deny)
```

**2. The agent answers with calls:** press, type, scroll, go to a page, or a tool of your app's.

**3. Your app runs them under your rules,** and the agent gets back what changed, not the whole tree again:

```text
Done.

The screen changed:
Now at /reply/42 (was /message/42) — can go back.
+ [w12 key=compose.body] textbox "Body" — read, write, append, clear
+ [w13 key=compose.send] button "Send" — press(deny)
```

It goes on like that, step by step, until the goal is done.

## A taste

Most controls are found by themselves. Name the ones that matter, and say what the agent may do:

=== "Flutter"

    ```dart
    ElevatedButton(onPressed: send, child: const Text('Send'))
        .afford('Send', key: 'compose.send', policy: Policy.deny);
    ```

=== "Web"

    ```html
    <button data-afford-key="compose.send" data-afford-policy="deny">Send</button>
    ```

The app answers the agent's requests over the channel it already has; where the model runs, `AffordRemote` turns them into its
tools:

```ts
import { AffordRemote, anthropicTools, anthropicResult } from 'affordkit';

const ui = new AffordRemote({ send: (request) => askTheApp(request) }); // the app: kit.answer(request)
const res = await client.messages.create({ model, max_tokens, messages, tools: anthropicTools(ui.tools()) });
```

## What it takes care of

- **Long lists:** one node with a preview; the agent searches, fetches and scrolls to the entry it wants.
- **Pages:** the agent knows where the user is, can go to a page, or look at one before going.
- **Your rules:** `allow`, `confirm` (the user says yes first), `deny` (the user's own act). Passwords are never read.
- **Waiting for the screen:** each step answers once what it set off (a search, a page loading) has shown; your app says when.
- **The user's own hands:** what they do while the agent works goes to it, with the screen as it is after.
- **The user leaving:** the agent finishes another way and leaves a handoff, a way back to what it did.
