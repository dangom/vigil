// Fires at pi/vigil.ts the events pi fires at an extension, shaped as pi
// 1.5.2 shapes them, for tests/test_hook.bats.  No pi is needed, and no model.
//
//   node tests/pi-events.mjs pi/vigil.ts <directory to work in>

import { existsSync, readdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const [extension, cwd] = process.argv.slice(2);
const handlers = {};
(await import(extension)).default({
  on: (name, handler) => (handlers[name] ??= []).push(handler),
});
let tokens = 1000;
const ctx = {
  cwd,
  model: { provider: "ollama", id: "flint" },
  sessionManager: { getSessionId: () => "pi-session-1", getSessionFile: () => "/sessions/s.jsonl" },
  getContextUsage: () => ({ tokens: (tokens += 100) }),
};
// pi waits for a handler that is not done yet, as for the one of `input'.
const fire = async (name, event = {}) => {
  for (const handler of handlers[name] ?? []) await handler({ type: name, ...event }, ctx);
};
const call = async (id, tool, input, result, isError = false) => {
  await fire("tool_execution_start", { toolCallId: id, toolName: tool, args: input });
  await fire("tool_call", { toolCallId: id, toolName: tool, input });
  await fire("tool_execution_end", { toolCallId: id, toolName: tool, result, isError, durationMs: 3 });
};

writeFileSync(join(cwd, "notes.txt"), "alpha\nbeta\ngamma\n");
await fire("session_start", { reason: "startup" });
await fire("input", { text: "fix notes.txt", source: "interactive" });
// What the agent goes on to do, once pi has let it.
writeFileSync(join(cwd, "after-prompt.txt"), "written after the prompt\n");
await fire("input", { text: "said by an extension", source: "extension" });
await fire("before_agent_start", { messageType: "user", prompt: "fix notes.txt" });
await call(
  "c1", "edit", { path: "notes.txt", edits: [{ oldText: "beta", newText: "BETA" }] },
  {
    content: [{ type: "text", text: "Successfully replaced 1 block(s) in notes.txt." }],
    details: { patch: "--- notes.txt\n+++ notes.txt\n@@ -1,3 +1,3 @@\n alpha\n-beta\n+BETA\n gamma\n" },
  },
);
await call("c2", "write", { path: "new.txt", content: "made by write" },
     { content: [{ type: "text", text: "Successfully wrote to new.txt" }] });
await fire("agent_end", {
  messages: [
    { role: "user", content: [{ type: "text", text: "fix notes.txt" }] },
    { role: "assistant",
      content: [{ type: "thinking", thinking: "Nearly there." }, { type: "text", text: "Fixed." }] },
  ],
});
await fire("agent_settled", { aborted: false });
// pi stays until it is told to go; what is still waiting when it goes is
// handed over all at once, in no order.  Here, as mostly, nothing is.
const records = join(process.env.VIGIL_RECORDS_DIR ?? "", process.env.COOKED_HOST_SESSION ?? "");
for (let n = 0; n < 100 && process.env.COOKED_HOST_SESSION; n++) {
  if (existsSync(records) && readdirSync(records).filter((f) => f.endsWith(".json")).length >= 7) break;
  await new Promise((done) => setTimeout(done, 100));
}
await fire("session_shutdown", { reason: "quit" });
