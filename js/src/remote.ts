/**
 * The agent's side of AffordKit over any transport. Give it a way to send a request to the app (which answers with its kit's
 * answer()), and it gives the agent its tools and runs them: each answer as text for the model — after an act, what it did to the
 * screen rather than the whole tree again — with a code when it failed.
 *
 *   const ui = new AffordRemote({ send: (request) => socket.ask(request) });   // the app: socket.onAsk((r) => kit.answer(r))
 *   tools.push(...anthropicTools(ui.tools()));
 *   const { text, isError } = await ui.handle(toolUse.name, toolUse.input);   // → the tool_result
 */

import { AGENT_TOOLS, describe, describeChange, describeResult, toCall, type AgentTool } from './agent.js';
import { AffordError, isImage, type AffordContext, type Call, type ErrorCode, type ImageValue, type UiAnswer, type UiRequest } from './protocol.js';

export interface RemoteOptions {
  /** Send a request to the app and resolve with its answer (kit.answer on the app's side). */
  send: (request: UiRequest) => Promise<UiAnswer>;
  /** How long to wait for the app's answer (default 45 s): then the tool fails with code timeout. */
  timeoutMs?: number;
  /** The screen after an act: what changed (default: fewer tokens), or the whole tree each time. */
  screen?: 'changes' | 'whole';
  /** Which of AGENT_TOOLS to offer (default: all — ui_tool once the app is seen to have tools of its own). */
  tools?: string[];
  /** Most nodes in a tree as text. */
  maxNodes?: number;
}

/** A tool's answer: the text for the agent (its tool result), whether it failed and why, and the screen it left. */
export interface ToolAnswer {
  text: string;
  isError: boolean;
  code?: ErrorCode;
  context?: AffordContext;
  /** Pictures that go with the text (a look with picture, an op view): to pass to the model where its stack takes images. */
  images?: { mime: string; data: string }[];
}

export class AffordRemote {
  private last: AffordContext | null = null;

  constructor(private readonly options: RemoteOptions) {}

  /** The screen as the agent was last shown it (e.g. sent along with the user's message): the next act answers with what changed since. */
  seen(context: AffordContext | null): void {
    this.last = context;
  }

  /** The screen as the agent last saw it. */
  get screen(): AffordContext | null {
    return this.last;
  }

  /** The tools to give the agent. */
  tools(): AgentTool[] {
    const names = this.options.tools;
    return AGENT_TOOLS.filter((t) => (names ? names.includes(t.name) : t.name !== 'ui_tool' || !this.last || this.last.tools.length > 0));
  }

  /** Whether a tool the agent called is one of these. */
  has(name: string): boolean {
    return this.tools().some((t) => t.name === name);
  }

  /** Run a tool the agent called: its answer as text. Never throws: a failure is an answer with isError and a code. */
  async handle(name: string, input: Record<string, unknown> = {}): Promise<ToolAnswer> {
    let call: Call | null;
    try {
      call = toCall(name, input ?? {});
    } catch (error) {
      return failed('bad_args', (error as Error).message);
    }
    const answer = await this.ask(call ? { calls: [call] } : { look: true, ...(input?.picture === true ? { picture: true } : {}) });
    if ('error' in answer) return failed(answer.code ?? 'unavailable', answer.error);
    const before = this.last;
    this.last = answer.context;
    const max = { maxNodes: this.options.maxNodes ?? 400 };
    if (!call) {
      const picture = answer.picture?.data ? [{ mime: answer.picture.mime, data: answer.picture.data }] : [];
      const note = input?.picture === true ? (picture.length ? '\n\n(A picture of the screen is attached.)' : '\n\n(No picture: this app can\'t take one.)') : '';
      return { text: describe(answer.context, max) + note, isError: false, context: answer.context, ...(picture.length ? { images: picture } : {}) };
    }
    const r = answer.results?.[0];
    if (!r) return failed('unavailable', 'The app gave no result');
    // A peek leaves the screen as it was; anything else: what it did to it (going to a page says where it is now itself)
    const said = r.ok && 'navigate' in call && before && this.options.screen !== 'whole' ? '' : describeResult(r);
    const screen = 'peek' in call ? '' : this.options.screen === 'whole' || !before ? `The screen now:\n${describe(answer.context, max)}` : describeChange(before, answer.context, max);
    const image = isImage(r.value) && r.value.data ? [{ mime: r.value.mime, data: r.value.data }] : [];
    return { text: [said, screen].filter(Boolean).join('\n\n'), isError: !r.ok, ...(r.code ? { code: r.code } : {}), context: answer.context, ...(image.length ? { images: image } : {}) };
  }

  private ask(request: UiRequest): Promise<UiAnswer> {
    const ms = this.options.timeoutMs ?? 45_000;
    return new Promise((resolve) => {
      const timer = setTimeout(() => resolve({ error: 'The app did not answer in time (it may be in the background): look again later, or do it another way', code: 'timeout' }), ms);
      this.options.send(request).then(
        (answer) => {
          clearTimeout(timer);
          resolve(answer);
        },
        (error: unknown) => {
          clearTimeout(timer);
          resolve({ error: (error as Error)?.message ?? String(error), code: error instanceof AffordError ? error.code : 'unavailable' });
        },
      );
    });
  }
}

function failed(code: ErrorCode, error: string): ToolAnswer {
  return { text: `Failed (${code}): ${error}`, isError: true, code };
}
