// vigil.ts -- what pi did, handed to `vigil hook' for Emacs to show.
//
// Installed by `vigil install-hooks --agent pi' into pi's extensions
// (~/.pi/agent/extensions/vigil.ts).  Claude Code reports to hooks named in
// its settings; pi reports to extensions, and this one passes each report on
// to the same `vigil hook', on its standard input, one after another and
// without pi waiting for any:
//
//   session_start        -> SessionStart      source: pi's reason
//   input                -> UserPromptSubmit  prompt: the text as typed
//   tool_call            -> PreToolUse        tool_input: pi's, as given
//   tool_execution_end   -> PostToolUse       tool_response: pi's result, as given
//   agent_settled        -> Stop              last_assistant_message
//
// The names around a report are the ones `vigil hook' already files by
// (hook_event_name, session_id, cwd, tool_use_id, ...), with "agent": "pi"
// to say whose it is.  What is inside -- a tool's input, its result -- is
// pi's own, untouched; emacs/vigil-pi.el reads it.
//
// Two things pi does not report are added, because nothing can find them out
// afterwards: how much context the model had read when it made a call
// (context_tokens), and the file an edit or a write is about to change, as it
// was before (original_file; or created, where there was none).
//
// Nothing here opens a connection, and nothing here can stop or change what
// pi does: every handler returns nothing, and a `vigil' that is missing or
// fails is not noticed.  Outside one of cooked's hosted sessions nothing is
// started at all, unless everything is archived (VIGIL_ARCHIVE_ALL=1).

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { spawn } from "node:child_process";
import { readFileSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { resolve } from "node:path";

// The biggest file kept as it was before an edit.
const ORIGINAL_MAX = 1024 * 1024;

function wanted(): boolean {
  const env = process.env;
  if (env.VIGIL_ARCHIVE_ALL === "1" && env.VIGIL_ARCHIVE !== "0") return true;
  return Boolean(env.VIGIL_SESSION || env.COOKED_HOST_SESSION);
}

// What every report says of where it comes from.  First, and short: `vigil
// hook' looks for the session and the event at the start of a report.
function envelope(name: string, ctx: any): Record<string, unknown> {
  let session: unknown, file: unknown, model: unknown, cwd: unknown;
  try {
    session = ctx.sessionManager.getSessionId();
    file = ctx.sessionManager.getSessionFile();
  } catch {}
  try {
    cwd = ctx.cwd;
    model = ctx.model ? `${ctx.model.provider}/${ctx.model.id}` : undefined;
  } catch {}
  return {
    hook_event_name: name,
    agent: "pi",
    session_id: session ?? "unknown",
    cwd,
    transcript_path: file,
    model,
  };
}

// Reports waiting for the hook, oldest first, each with when it happened.
const waiting: { text: string; time: string }[] = [];
let handing = false;

// One hook at a time, in the order things happened: the archive keeps
// reports in the order they arrive.  pi never waits for any of them.
function hand(): void {
  if (handing) return;
  const next = waiting.shift();
  if (!next) return;
  handing = true;
  let over = false;
  const done = () => {
    if (over) return;
    over = true;
    handing = false;
    hand();
  };
  try {
    const child = spawn(process.env.VIGIL_BIN || "vigil", ["hook"], {
      stdio: ["pipe", "ignore", "ignore"],
      env: { ...process.env, VIGIL_EVENT_TIME: next.time },
    });
    child.on("error", done);
    child.on("exit", done);
    child.stdin.on("error", () => {});
    child.stdin.end(next.text + "\n");
    child.unref();
  } catch {
    done();
  }
}

// pi is going: what is still waiting is handed over all at once.
function flush(): void {
  while (waiting.length > 0) {
    handing = false;
    hand();
  }
}

function report(event: Record<string, unknown>): void {
  if (!wanted()) return;
  try {
    waiting.push({ text: JSON.stringify(event), time: (Date.now() / 1000).toFixed(6) });
  } catch {
    return;
  }
  hand();
}

// The file PATH names, as pi's tools take it: under CWD, or the home directory.
function absolute(path: string, cwd: string): string {
  if (path === "~") return homedir();
  if (path.startsWith("~/")) return resolve(homedir(), path.slice(2));
  return resolve(cwd, path);
}

// The file as it is now: its text; null if there is none; undefined if it
// cannot be said -- too big, not a file, not to be read.
function original(path: unknown, cwd: unknown): string | null | undefined {
  if (typeof path !== "string" || typeof cwd !== "string") return undefined;
  try {
    const file = absolute(path, cwd);
    const stat = statSync(file, { throwIfNoEntry: false });
    if (!stat) return null;
    if (!stat.isFile() || stat.size > ORIGINAL_MAX) return undefined;
    return readFileSync(file, "utf8");
  } catch {
    return undefined;
  }
}

// The words of MESSAGE, a message of the model's, without its thinking.
function words(message: any): string | undefined {
  if (!message || message.role !== "assistant") return undefined;
  if (typeof message.content === "string") return message.content;
  if (!Array.isArray(message.content)) return undefined;
  return message.content
    .filter((part: any) => part && part.type === "text" && typeof part.text === "string")
    .map((part: any) => part.text)
    .join("\n");
}

export default function (pi: ExtensionAPI) {
  // What each call under way was given, and the file it is changing as it was.
  const calls = new Map<string, { input?: unknown; original?: string | null }>();
  // The model's last words in the run that is ending.
  let reply: string | undefined;

  pi.on("session_start", (event: any, ctx: any) => {
    calls.clear();
    reply = undefined;
    report({ ...envelope("SessionStart", ctx), source: event.reason });
  });

  pi.on("session_shutdown", () => flush());

  pi.on("input", (event: any, ctx: any) => {
    // One an extension sent is not one the agent was given.
    if (event.source === "extension" || typeof event.text !== "string") return;
    report({
      ...envelope("UserPromptSubmit", ctx),
      streaming_behavior: event.streamingBehavior,
      prompt: event.text,
    });
  });

  pi.on("tool_execution_start", (event: any) => {
    calls.set(event.toolCallId, { input: event.args });
  });

  pi.on("tool_call", (event: any, ctx: any) => {
    const call = calls.get(event.toolCallId) ?? {};
    // As it is about to run: an earlier handler may have changed it.
    call.input = event.input;
    if (event.toolName === "edit" || event.toolName === "write") {
      call.original = original(event.input?.path, ctx.cwd);
    }
    calls.set(event.toolCallId, call);
    let tokens: unknown;
    try {
      tokens = ctx.getContextUsage()?.tokens;
    } catch {}
    report({
      ...envelope("PreToolUse", ctx),
      tool_name: event.toolName,
      tool_use_id: event.toolCallId,
      parent_tool_use_id: event.parentToolCallId,
      context_tokens: typeof tokens === "number" ? tokens : undefined,
      tool_input: event.input,
    });
  });

  // Every call ends here, one that was refused or never ran included.
  pi.on("tool_execution_end", (event: any, ctx: any) => {
    const call = calls.get(event.toolCallId) ?? {};
    calls.delete(event.toolCallId);
    report({
      ...envelope("PostToolUse", ctx),
      tool_name: event.toolName,
      tool_use_id: event.toolCallId,
      parent_tool_use_id: event.parentToolCallId,
      duration_ms: event.durationMs,
      is_error: Boolean(event.isError),
      tool_input: call.input,
      tool_response: event.result,
      // JSON's null is nothing to Emacs: a file that was not there is said.
      created: call.original === null ? true : undefined,
      original_file: call.original ?? undefined,
    });
  });

  pi.on("agent_end", (event: any) => {
    const messages = Array.isArray(event.messages) ? event.messages : [];
    for (let i = messages.length - 1; i >= 0; i--) {
      const text = words(messages[i]);
      if (text !== undefined) {
        reply = text;
        break;
      }
    }
  });

  // Settled: pi will not go on by itself.  A run that ended only to be tried
  // again, or to take up what was queued, has not replied yet.
  pi.on("agent_settled", (event: any, ctx: any) => {
    report({
      ...envelope("Stop", ctx),
      aborted: Boolean(event.aborted),
      last_assistant_message: reply,
    });
    reply = undefined;
  });
}
