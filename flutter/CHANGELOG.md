## 0.1.0

- Initial release.
- Handoffs, for when the user has left the app: `AffordAgent`'s `present` (in `kit.agent()`, the app's lifecycle) makes the
  screen tools answer `ErrorCode.away` at once; with `onHandoff`, the agent gets `ui_handoff` to leave a message and calls by key;
  `Handoff`, `parseHandoff` and `handoffProblem` check one; `AffordKit.runHandoff(handoff)` runs it when the user comes back.
  Error codes `away` and `expired`.
