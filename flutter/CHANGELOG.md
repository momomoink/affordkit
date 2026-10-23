## 0.1.0

- Initial release.
- Handoffs, for when the user has left the app: `AffordAgent`'s `present` (in `kit.agent()`, the app's lifecycle) makes the
  screen tools answer `ErrorCode.away` at once; with `onHandoff`, the agent gets `ui_handoff` to leave a message and calls by key;
  `Handoff`, `parseHandoff` and `handoffProblem` check one; `AffordKit.runHandoff(handoff)` runs it when the user comes back.
  Error codes `away` and `expired`.
- What the user does meanwhile: `kit.watchUser(true)` notes what the user does themselves (press, toggle, select, write — never a
  password's text — navigate, back; never the kit's own calls), and the next `answer` carries it as `userActions` (`UserAction`,
  `takeUserActions()`, `onUserAction`); `AffordAgent` puts it at the top of the tool's answer (`describeUserActions`).
