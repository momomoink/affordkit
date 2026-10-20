## 0.1.0

- Initial release.
- Handoffs, for when the user has left the app: `AffordRemote`'s `present` makes the screen tools answer code `away` at once;
  with `onHandoff`, the agent gets `ui_handoff` to leave a message and calls by key; `parseHandoff`, `handoffProblem` and
  `handoffExpired` check one; `kit.runHandoff(handoff)` runs it in the page when the user comes back. Error codes `away` and
  `expired`.
