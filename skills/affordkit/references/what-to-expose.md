# What to expose

The agent acts as the user, inside the user's session. Anything it can reach, it can do with the user's rights. Decide per
control which of four things applies.

## The four choices

| Choice | Use it for | How |
|---|---|---|
| **Allow** | Reversible actions inside the app the user can see or undo: opening, navigating, searching, filtering, typing into a draft, starring, marking read, archiving. | the default |
| **Confirm** | Actions that are hard to undo, or that go out of the app on the user's behalf, when the user still wants the agent to do them: deleting, unsubscribing, accepting an invite, changing an account setting. | `policy: confirm`, and a `confirm` callback that asks the user |
| **Deny** | Actions that must be the user's own act: sending a message, paying, publishing, signing, granting a permission. The agent can still see the control and point the user to it. | `policy: deny` |
| **Leave out** | What the agent should not even see: other people's private data on shared screens, admin panels, the agent's own chat panel, secrets. | don't afford it (Flutter), `data-afford-skip` / `skip` (web) |

When in doubt between two, take the stricter one. It is easy to loosen a policy once you trust it; a message sent by mistake
cannot be unsent.

## Rules of thumb

- **Send is the user's.** Let the agent write the reply, fill in the form, put the order in the cart. Deny the final button.
  The user reviews and presses it.
- **Secrets are never readable.** Passwords, one-time codes, API keys and tokens: the kit denies password fields by itself (web:
  also fields named like tokens or keys; mark others with `data-afford-secret`). The agent sees that the field exists and whether
  it is filled, never its content.
- **Deny what moves money or rights.** Payments, transfers, purchases, subscriptions, role and permission changes, sharing
  settings.
- **Confirm what deletes or leaves the app.** Permanent deletes, emptying trash, unsubscribing, accepting or declining for the
  user, posting to other services.
- **Policies apply to every way in.** A denied button is denied whether the agent taps it or calls a custom op on its row. Give a
  custom op the same policy as the control it stands for, and give app tools a policy too.
- **Don't add backdoors.** A custom op or app tool that does what a denied button does (a `send_now` tool next to a denied Send)
  undoes the policy. Expose actions at the strictness the UI has.
- **Keep the agent's own UI out.** The chat panel, its history and its settings: an agent that can press "new chat" on itself,
  or read its own transcript as screen content, gets confused.

## Make it easy to use well

- **Name things as the user would.** The name is what the agent tells the user ("I pressed Reply"). Use the visible label; add a
  `description` when the label is an icon or ambiguous ("Archive: moves the mail out of the inbox").
- **Give keys to what the agent uses often.** Keys (`compose.body`, `thread.reply`) stay the same across visits, so the agent can
  act right after navigating, without looking first. Use a stable scheme: `<screen>.<control>`.
- **One node per meaning.** Afford the button, not the button and its icon and its label. Group related controls in a `region`
  so the tree reads like the screen.
- **Containers for anything long.** A list over a couple of dozen entries, anything virtualized or paged. Give `items` a real
  search when the data lives on a server.
- **Say the state.** A custom toggle that does not say `checked` makes the agent guess and toggle twice.
- **Prefer taps the user can see** for what the user is watching: the agent opening the mail and pressing Reply is something the
  user can follow and stop. Use custom ops and app tools for what has no good path on screen, or would be a long detour.

## Check it

Print the tree the model reads (`describe(kit.context())`) for each main screen and look for:

- buttons without a name, or two controls with the same name;
- anything that sends, pays, deletes or changes rights without `deny` or `confirm`;
- secrets, or other people's data, in the tree;
- long lists that are not containers;
- custom ops or tools that reach past a denied control.

In tests, assert the policies of the dangerous controls, so a later change can't loosen them by accident.
