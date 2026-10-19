# What to expose

The agent acts as the user, inside the user's session. Anything it can reach, it can do with the user's rights. Decide per
widget which of four things applies.

## The four choices

| Choice | Use it for | How |
|---|---|---|
| **Allow** | Reversible actions inside the app the user can see or undo: opening, navigating, searching, filtering, typing into a draft, starring, marking read, archiving. | the default |
| **Confirm** | Actions that are hard to undo, or that go out of the app on the user's behalf, when the user still wants the agent to do them: deleting, unsubscribing, accepting an invite, changing an account setting. | `policy: Policy.confirm`, and a `confirm` callback that asks the user |
| **Deny** | Actions that must be the user's own act: sending a message, paying, publishing, signing, granting a permission. The agent can still see the widget and point the user to it. | `policy: Policy.deny` |
| **Leave out** | What the agent should not even see: other people's private data on shared screens, admin screens, the agent's own chat panel, secrets. | don't afford it |

When in doubt between two, take the stricter one. It is easy to loosen a policy once you trust it; a message sent by mistake
cannot be unsent.

Because the Flutter tree is built by addition, nothing is exposed until you afford it. Leaving out is the default; the risk is
the other way round: a dangerous button afforded through a shared component without a policy.

## Rules of thumb

- **Send is the user's.** Let the agent write the reply, fill in the form, put the order in the cart. Deny the final button.
  The user reviews and presses it.
- **Secrets are never readable.** Obscured text fields are denied by themselves. Don't afford other secret fields (API keys,
  recovery codes), or deny them. The agent should see at most that the field exists.
- **Deny what moves money or rights.** Payments, transfers, purchases, subscriptions, role and permission changes, sharing
  settings.
- **Confirm what deletes or leaves the app.** Permanent deletes, emptying trash, unsubscribing, accepting or declining for the
  user, posting to other services.
- **Policies apply to every way in.** A denied button is denied whether the agent taps it or calls a `CustomOp` on its row. Give a
  custom op the same policy as the widget it stands for, and give app tools a policy too.
- **Don't add backdoors.** A `CustomOp` or `AffordTool` that does what a denied button does (a `send_now` tool next to a denied
  Send) undoes the policy. Expose actions at the strictness the UI has.
- **Watch shared components.** A title bar button or a list row that affords itself does so on every screen. Give it a way to
  take a `policy` (and a way to opt out), and pass `Policy.deny` where it sends or pays.
- **Keep the agent's own UI out.** Its chat sheet, history and settings: don't afford them (a component that affords itself
  should be able to opt out).

## Make it easy to use well

- **Name things as the user would.** The name is what the agent tells the user ("I pressed Reply"). Use the visible label or the
  tooltip; add a `description` for icon-only or ambiguous widgets.
- **Give keys to what the agent uses often.** Keys (`compose.body`, `thread.reply`) stay the same across visits, so the agent can
  act right after navigating, without looking first. Use a stable scheme: `<screen>.<control>`.
- **One node per meaning.** Afford the button, not the button and its icon and its label. Group related widgets in a
  `Role.region` so the tree reads like the screen.
- **Containers for anything long.** A list over a couple of dozen entries, anything paged. Give `items` a real search when the
  data lives on a server.
- **Say the state.** A widget of your own that does not pass `state: {'checked': ...}` makes the agent guess and toggle twice.
- **Prefer taps the user can see** for what the user is watching: the agent opening the mail and pressing Reply is something the
  user can follow and stop. Use custom ops and app tools for what has no good path on screen.

## Check it

Print the tree the model reads for each main screen:

```dart
debugPrint(describe(AffordKit.instance.context().toJson()));
```

Look for widgets without a name or two with the same name; anything that sends, pays, deletes or changes rights without `deny` or
`confirm`; secrets or other people's data; long lists that are not containers; custom ops or tools that reach past a denied
widget.

In widget tests, pump a screen and assert on `kit.context()`: the keys you expect, and the policies of the dangerous widgets, so a
later change can't loosen them by accident.
