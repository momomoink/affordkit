# What to expose

The agent acts as the user, inside the user's session. Anything it can reach, it can do with the user's rights. Decide per
control which of four things applies.

## The four choices

| Choice | Use it for | How |
|---|---|---|
| **Allow** | Reversible actions inside the app the user can see or undo: opening, navigating, searching, filtering, typing into a draft, starring, marking read, archiving. | the default |
| **Confirm** | Actions that are hard to undo, or that go out of the app on the user's behalf, when the user still wants the agent to do them: deleting, unsubscribing, accepting an invite, changing an account setting. | `data-afford-policy="confirm"` or `policy: 'confirm'`, and a `confirm` option that asks the user |
| **Deny** | Actions that must be the user's own act: sending a message, paying, publishing, signing, granting a permission. The agent can still see the control and point the user to it. | `data-afford-policy="deny"` or `policy: 'deny'` |
| **Leave out** | What the agent should not even see: other people's private data on shared screens, admin panels, the agent's own chat panel, secrets. | `data-afford-skip`, `register(el, { skip: true })`, or the kit's `skip` selector |

When in doubt between two, take the stricter one. It is easy to loosen a policy once you trust it; a message sent by mistake
cannot be unsent.

Because the web tree is built by subtraction, everything visible is in it by default. Go through each screen for what to deny
or leave out; don't assume that what you did not mark is hidden.

## Rules of thumb

- **Send is the user's.** Let the agent write the reply, fill in the form, put the order in the cart. Deny the final button.
  The user reviews and presses it.
- **Secrets are never readable.** Password fields, and fields named like tokens, API keys or one-time codes, are denied by
  themselves; mark any other secret field with `data-afford-secret`. The agent sees that the field exists and whether it is
  filled, never its content.
- **Deny what moves money or rights.** Payments, transfers, purchases, subscriptions, role and permission changes, sharing
  settings.
- **Confirm what deletes or leaves the app.** Permanent deletes, emptying trash, unsubscribing, accepting or declining for the
  user, posting to other services.
- **Policies apply to every way in.** A denied button is denied whether the agent clicks it or calls a custom op on its row. Give
  a custom op the same policy as the control it stands for, and give app tools a policy too.
- **Don't add backdoors.** A custom op or app tool that does what a denied button does (a `send_now` tool next to a denied Send)
  undoes the policy. Expose actions at the strictness the UI has.
- **Keep the agent's own UI out.** Its chat panel, history and settings: pass their container as the kit's `skip` selector.

## Make it easy to use well

- **Name things as the user would.** The name is what the agent tells the user ("I pressed Reply"). Use the visible label; add
  `data-afford-describe` for icon-only or ambiguous controls.
- **Give keys to what the agent uses often.** Keys (`compose.body`, `thread.reply`) stay the same across visits, so the agent can
  act right after navigating, without looking first. Use a stable scheme: `<screen>.<control>`.
- **One node per meaning.** Give an icon-only button a name rather than leaving its icon to speak; mark a group that belongs
  together (a toolbar, a filter bar) with `data-afford-role="region"` and a name.
- **Containers for anything long.** A list over a couple of dozen entries, anything virtualized or paged. Give `items` a real
  search when the data lives on a server.
- **Say the state.** A custom toggle should carry `aria-checked` (or `aria-pressed`, `aria-selected`), or the agent guesses.
- **Prefer clicks the user can see** for what the user is watching. Use custom ops and app tools for what has no good path on
  screen, or would be a long detour.

## Check it

Print the tree the model reads for each main screen:

```ts
import { describe } from 'affordkit';
console.log(describe(kit.context()));
```

Look for buttons without a name or two controls with the same name; anything that sends, pays, deletes or changes rights without
`deny` or `confirm`; secrets or other people's data; long lists that are not containers; custom ops or tools that reach past a
denied control.

In tests, render a screen and assert the policies of the dangerous controls, so a later change can't loosen them by accident.
