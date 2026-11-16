#!/usr/bin/env bats
# bin/vigil: the hook that keeps reports, and the commands that install it.
#
#   bats tests

setup() {
  TEST_TEMP="$(mktemp -d)"
  export HOME="$TEST_TEMP/home"
  export VIGIL_DATA_DIR="$TEST_TEMP/data"
  export VIGIL_RECORDS_DIR="$VIGIL_DATA_DIR/records"
  export VIGIL_RECORD_MAX=4194304
  export VIGIL_RECORDS_MAX=2000
  export VIGIL_KEEP_DAYS=14
  export VIGIL_PROMPT_HISTORY="$VIGIL_DATA_DIR/prompts.jsonl"
  export VIGIL_PROMPT_HISTORY_MAX=5000
  export VIGIL_ARCHIVE_DIR="$VIGIL_DATA_DIR/archive"
  export VIGIL_ARCHIVE_RECORD_MAX=1048576
  export VIGIL_SETTINGS="$HOME/.claude/settings.json"
  unset VIGIL_ARCHIVE VIGIL_ARCHIVE_ALL VIGIL_SESSION COOKED_HOST_SESSION
  unset CLAUDE_CODE_SHELL_PREFIX XDG_STATE_HOME
  export COOKED_RUN_DIR="$TEST_TEMP/runs"
  mkdir -p "$HOME"
  export VIGIL_TESTING=1
  # shellcheck disable=SC1091
  source "$BATS_TEST_DIRNAME/../bin/vigil"
  # Fail closed if the entry point ever points these tests at real records.
  case "$VIGIL_DATA_DIR" in
    "$TEST_TEMP"/*) ;;
    *) echo "Unsafe test VIGIL_DATA_DIR: $VIGIL_DATA_DIR" >&2; return 1 ;;
  esac
}

teardown() {
  [ -d "${TEST_TEMP:-}" ] && rm -rf "$TEST_TEMP"
}

# --- the hook ---------------------------------------------------------------------

_tool_event() {
  # A PostToolUse payload as Claude Code writes it, pretty-printed on purpose:
  # the record must still come out on one line.
  printf '{\n  "hook_event_name": "PostToolUse",\n  "tool_name": "Bash",\n  "tool_use_id": "%s",\n  "tool_input": {"command": "printf \\"a\\\\nb\\""},\n  "tool_response": {"stdout": "a\\nb", "stderr": ""}\n}\n' "$1"
}

@test "the hook records the event, on one line, under the session's name" {
  export COOKED_HOST_SESSION="proj.1"
  _tool_event toolu_1 | vigil_hook
  local files=("$VIGIL_RECORDS_DIR/proj.1"/*.json)
  [ "${#files[@]}" -eq 1 ]
  [ "$(wc -l < "${files[0]}")" -eq 1 ]
  [ "$(jq -r .tool_use_id "${files[0]}")" = "toolu_1" ]
  [ "$(jq -r .tool_response.stdout "${files[0]}")" = $'a\nb' ]
}

@test "VIGIL_SESSION names the session over COOKED_HOST_SESSION" {
  export COOKED_HOST_SESSION="proj.1" VIGIL_SESSION="mine"
  _tool_event toolu_1 | vigil_hook
  [ -d "$VIGIL_RECORDS_DIR/mine" ]
  [ ! -d "$VIGIL_RECORDS_DIR/proj.1" ]
}

@test "the hook keeps one file per event" {
  export COOKED_HOST_SESSION="proj.1"
  _tool_event toolu_1 | vigil_hook
  _tool_event toolu_2 | vigil_hook
  local files=("$VIGIL_RECORDS_DIR/proj.1"/*.json)
  [ "${#files[@]}" -eq 2 ]
  # No temporary file left behind.
  [ -z "$(find "$VIGIL_DATA_DIR" -name '.*.tmp' -o -name '.event.*')" ]
}

@test "the hook writes nothing outside a hosted session" {
  _tool_event toolu_1 | vigil_hook
  [ ! -d "$VIGIL_DATA_DIR" ]
}

@test "the hook refuses a session name that is a path" {
  export COOKED_HOST_SESSION="../escape"
  _tool_event toolu_1 | vigil_hook
  [ ! -d "$VIGIL_RECORDS_DIR" ]
  [ ! -d "$VIGIL_DATA_DIR/escape" ]
}

@test "the hook keeps only the newest VIGIL_RECORDS_MAX" {
  export COOKED_HOST_SESSION="proj.1"
  export VIGIL_RECORDS_MAX=3
  local i
  # The name's time, pinned where bash lets it be (3.2, where it is an
  # ordinary variable); bash 5's own clock only ever increases anyway.
  for i in 1 2 3 4 5; do
    EPOCHREALTIME="170000000$i.000000" vigil_hook < <(_tool_event "toolu_$i")
  done
  local files=("$VIGIL_RECORDS_DIR/proj.1"/*.json)
  [ "${#files[@]}" -eq 3 ]
  [ "$(jq -r .tool_use_id "${files[0]}")" = "toolu_3" ]
  [ "$(jq -r .tool_use_id "${files[2]}")" = "toolu_5" ]
}

@test "what is kept is readable by its owner only" {
  export COOKED_HOST_SESSION="proj.1"
  printf '{"hook_event_name": "UserPromptSubmit", "session_id": "s", "prompt": "secret"}\n' \
    | "$BATS_TEST_DIRNAME/../bin/vigil" hook
  local file
  while IFS= read -r file; do
    [ -z "$(find "$file" -perm +077)" ] || { echo "open to others: $file"; return 1; }
  done < <(find "$VIGIL_DATA_DIR")
  [ -n "$(find "$VIGIL_ARCHIVE_DIR" -name s.jsonl)" ]
}

@test "nothing in vigil opens a connection" {
  # No program that talks to another machine is named anywhere in it.
  ! grep -nEw 'curl|wget|nc|ncat|netcat|ssh|scp|sftp|rsync|ftp|telnet|socat|urllib|requests|socket|http|https' \
      "$BATS_TEST_DIRNAME/../bin/vigil" "$BATS_TEST_DIRNAME/../bin/vigil-shell"
  ! grep -nE 'url-retrieve|make-network-process|open-network-stream|url-copy-file|url-http' \
      "$BATS_TEST_DIRNAME"/../emacs/*.el
}

# --- a session starting -----------------------------------------------------------

_start_event() {
  printf '{"session_id": "s", "hook_event_name": "SessionStart", "source": "%s"}\n' "$1"
}

@test "a new conversation clears what an earlier agent left under the name" {
  export COOKED_HOST_SESSION="proj.1"
  # Named for when they were written, as the hook names them.
  mkdir -p "$VIGIL_RECORDS_DIR/proj.1"
  _tool_event old_1 | tr -d '\n' > "$VIGIL_RECORDS_DIR/proj.1/1700000001.000000-1-1.json"
  _tool_event old_2 | tr -d '\n' > "$VIGIL_RECORDS_DIR/proj.1/1700000002-1-2.json"
  # A prompt this agent was started with may be recorded before its start is.
  _tool_event mine | vigil_hook
  _start_event startup | vigil_hook
  local ids
  ids=$(jq -r '.tool_use_id // .hook_event_name' "$VIGIL_RECORDS_DIR/proj.1"/*.json | LC_ALL=C sort | tr '\n' ' ')
  [ "$ids" = "SessionStart mine " ]
}

@test "a conversation resumed keeps its records" {
  export COOKED_HOST_SESSION="proj.1"
  mkdir -p "$VIGIL_RECORDS_DIR/proj.1"
  _tool_event old_1 | tr -d '\n' > "$VIGIL_RECORDS_DIR/proj.1/1700000001.000000-1-1.json"
  _start_event resume | vigil_hook
  _start_event compact | vigil_hook
  local files=("$VIGIL_RECORDS_DIR/proj.1"/*.json)
  [ "${#files[@]}" -eq 3 ]
}

@test "a session nothing has reported from in VIGIL_KEEP_DAYS is removed" {
  export COOKED_HOST_SESSION="proj.1"
  mkdir -p "$VIGIL_RECORDS_DIR/gone" "$VIGIL_RECORDS_DIR/recent"
  touch -t 202001010000 "$VIGIL_RECORDS_DIR/gone"
  _start_event resume | vigil_hook
  [ ! -d "$VIGIL_RECORDS_DIR/gone" ]
  [ -d "$VIGIL_RECORDS_DIR/recent" ]
  [ -d "$VIGIL_RECORDS_DIR/proj.1" ]
}

# --- install-hooks / uninstall-hooks ----------------------------------------------

_write_user_settings() {
  mkdir -p "$HOME/.claude"
  cat > "$VIGIL_SETTINGS" <<'JSON'
{
  "tui": "fullscreen",
  "hooks": {
    "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "my-linter"}]}],
    "Stop": [{"hooks": [{"type": "command", "command": "another-tool _hook idle"}]}]
  }
}
JSON
}

@test "install-hooks merges vigil's hook and keeps every other" {
  _write_user_settings
  run vigil_hooks install
  [ "$status" -eq 0 ]
  [ "$(jq -r .tui "$VIGIL_SETTINGS")" = "fullscreen" ]
  [ "$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$VIGIL_SETTINGS")" = "my-linter" ]
  [ "$(jq -r '.hooks.PreToolUse[1].hooks[0].command' "$VIGIL_SETTINGS")" = "vigil hook" ]
  [ "$(jq -r '.hooks.PreToolUse[1].hooks[0].async' "$VIGIL_SETTINGS")" = "true" ]
  for event in PostToolUse SubagentStart SubagentStop SessionStart UserPromptSubmit; do
    [ "$(jq -r ".hooks.${event}[0].hooks[0].command" "$VIGIL_SETTINGS")" = "vigil hook" ]
  done
  [ "$(jq -r '[.hooks.Stop[].hooks[0].command] | join(",")' "$VIGIL_SETTINGS")" = "another-tool _hook idle,vigil hook" ]
  ls "$VIGIL_SETTINGS".vigil-backup-* >/dev/null
}

@test "install-hooks twice changes nothing the second time" {
  _write_user_settings
  vigil_hooks install >/dev/null
  local first; first=$(cat "$VIGIL_SETTINGS")
  run vigil_hooks install
  [[ "$output" == *"Nothing to change"* ]]
  [ "$(cat "$VIGIL_SETTINGS")" = "$first" ]
}

@test "install-hooks --dry-run prints the diff and writes nothing" {
  _write_user_settings
  local before; before=$(cat "$VIGIL_SETTINGS")
  run vigil_hooks install --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *'+'*'vigil hook'* ]]
  [ "$(cat "$VIGIL_SETTINGS")" = "$before" ]
  ! ls "$VIGIL_SETTINGS".vigil-backup-* >/dev/null 2>&1
}

@test "install-hooks --settings writes the file it is given" {
  run vigil_hooks install --settings "$TEST_TEMP/other.json"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.hooks.Stop[0].hooks[0].command' "$TEST_TEMP/other.json")" = "vigil hook" ]
  [ ! -e "$VIGIL_SETTINGS" ]
}

@test "install-hooks refuses a settings file that is not JSON" {
  mkdir -p "$HOME/.claude"
  printf '{ "hooks": ' > "$VIGIL_SETTINGS"
  run vigil_hooks install
  [ "$status" -ne 0 ]
  [[ "$output" == *"not valid JSON"* ]]
  [ "$(cat "$VIGIL_SETTINGS")" = '{ "hooks": ' ]
}

@test "uninstall-hooks takes out only vigil's hook" {
  _write_user_settings
  local before; before=$(jq -cS . "$VIGIL_SETTINGS")
  vigil_hooks install >/dev/null
  run vigil_hooks uninstall --dry-run
  [[ "$output" == *'-'*'vigil hook'* ]]
  run vigil_hooks uninstall
  [ "$status" -eq 0 ]
  [ "$(jq -cS . "$VIGIL_SETTINGS")" = "$before" ]
}

@test "install-hooks and uninstall-hooks never overwrite a backup" {
  _write_user_settings
  echo "the user's own" > "$VIGIL_SETTINGS.bak"
  vigil_hooks install >/dev/null
  vigil_hooks uninstall >/dev/null
  _write_user_settings
  vigil_hooks install >/dev/null
  # The .bak untouched, and one backup per change, none overwritten (two may
  # fall in the same second).
  [ "$(cat "$VIGIL_SETTINGS.bak")" = "the user's own" ]
  [ "$(ls "$VIGIL_SETTINGS".vigil-backup-* | wc -l)" -eq 3 ]
}

# --- prompt history ---------------------------------------------------------------

_prompt_event() {
  printf '{"hook_event_name": "UserPromptSubmit", "session_id": "s", "prompt": "%s"}\n' "$1"
}

@test "the hook keeps prompts in the history" {
  export COOKED_HOST_SESSION="proj.1"
  _prompt_event "fix the bug" | vigil_hook
  _tool_event toolu_1 | vigil_hook
  [ "$(wc -l < "$VIGIL_PROMPT_HISTORY")" -eq 1 ]
  [ "$(jq -r .host "$VIGIL_PROMPT_HISTORY")" = "proj.1" ]
  [ "$(jq -r .event.prompt "$VIGIL_PROMPT_HISTORY")" = "fix the bug" ]
  [ "$(jq -r '.time | type' "$VIGIL_PROMPT_HISTORY")" = "number" ]
}

@test "the prompt history outlives the session's records and is capped" {
  export COOKED_HOST_SESSION="proj.1"
  export VIGIL_PROMPT_HISTORY_MAX=10 VIGIL_RECORDS_MAX=3
  local i
  for i in $(seq 1 12); do _prompt_event "prompt $i" | vigil_hook; done
  # Over the cap by more than a tenth: cut back to the newest of them.
  [ "$(wc -l < "$VIGIL_PROMPT_HISTORY")" -eq 10 ]
  [ "$(tail -n 1 "$VIGIL_PROMPT_HISTORY" | jq -r .event.prompt)" = "prompt 12" ]
  local files=("$VIGIL_RECORDS_DIR/proj.1"/*.json)
  [ "${#files[@]}" -eq 3 ]
}

@test "the hook refuses a session name with odd characters" {
  export COOKED_HOST_SESSION='a"b'
  _prompt_event "x" | vigil_hook
  [ ! -d "$VIGIL_RECORDS_DIR" ]
  [ ! -f "$VIGIL_PROMPT_HISTORY" ]
}

# --- the archive ------------------------------------------------------------------

_session_event() {
  # $1 event name, $2 session id, $3 cwd
  printf '{"session_id": "%s", "hook_event_name": "%s", "cwd": "%s", "prompt": "hi"}\n' "$2" "$1" "$3"
}

@test "every event is archived verbatim, per session, with an index line" {
  export COOKED_HOST_SESSION="proj.1"
  local repo="$TEST_TEMP/repo"
  git init -q -b main "$repo"
  git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  _session_event SessionStart s1 "$repo" | vigil_hook
  _session_event UserPromptSubmit s1 "$repo" | vigil_hook
  _tool_event toolu_1 | sed 's/^{/{"session_id": "s1", /' | vigil_hook
  local file
  file=$(find "$VIGIL_ARCHIVE_DIR" -name s1.jsonl)
  [ "$(wc -l < "$file")" -eq 3 ]
  [ "$(jq -r .host "$file" | sort -u)" = "proj.1" ]
  [ "$(sed -n 3p "$file" | jq -r .event.tool_response.stdout)" = $'a\nb' ]
  [ "$(jq -r '.t | type' "$file" | sort -u)" = "number" ]
  [ "$(wc -l < "$VIGIL_ARCHIVE_DIR/index.jsonl")" -eq 1 ]
  [ "$(jq -r .git_branch "$VIGIL_ARCHIVE_DIR/index.jsonl")" = "main" ]
  [ "$(jq -r .git_commit "$VIGIL_ARCHIVE_DIR/index.jsonl")" = "$(git -C "$repo" rev-parse HEAD)" ]
  [ "$(jq -r .cwd "$VIGIL_ARCHIVE_DIR/index.jsonl")" = "$repo" ]
  [ "$(jq -r .hosted "$VIGIL_ARCHIVE_DIR/index.jsonl")" = "true" ]
}

@test "the archive outlives the session's own records" {
  export COOKED_HOST_SESSION="proj.1" VIGIL_RECORDS_MAX=2
  local i
  for i in 1 2 3 4 5; do _session_event UserPromptSubmit s1 /tmp | vigil_hook; done
  rm -rf "${VIGIL_RECORDS_DIR:?}/proj.1"
  [ "$(wc -l < "$(find "$VIGIL_ARCHIVE_DIR" -name s1.jsonl)")" -eq 5 ]
}

@test "VIGIL_ARCHIVE=0 keeps nothing in the archive" {
  export COOKED_HOST_SESSION="proj.1" VIGIL_ARCHIVE=0
  _session_event UserPromptSubmit s1 /tmp | vigil_hook
  [ ! -d "$VIGIL_ARCHIVE_DIR" ]
  [ "$(ls "$VIGIL_RECORDS_DIR/proj.1" | wc -l)" -eq 1 ]
}

@test "an agent outside a hosted session is archived only with VIGIL_ARCHIVE_ALL=1" {
  _session_event UserPromptSubmit s2 /tmp | vigil_hook
  [ ! -d "$VIGIL_ARCHIVE_DIR" ]
  VIGIL_ARCHIVE_ALL=1 vigil_hook < <(_session_event UserPromptSubmit s2 /tmp)
  local file; file=$(find "$VIGIL_ARCHIVE_DIR" -name s2.jsonl)
  [ "$(jq -r .hosted "$file")" = "false" ]
  [ "$(jq -r .host "$file")" = "null" ]
  [ "$(jq -r .hosted "$VIGIL_ARCHIVE_DIR/index.jsonl")" = "false" ]
  [ ! -d "$VIGIL_RECORDS_DIR" ]
}

@test "an oversized event is kept with its big parts marked, still JSON" {
  export COOKED_HOST_SESSION="proj.1" VIGIL_ARCHIVE_RECORD_MAX=2000 VIGIL_RECORD_MAX=2000
  local big; big=$(head -c 30000 /dev/zero | tr '\0' x)
  printf '{"session_id": "s3", "hook_event_name": "PostToolUse", "tool_name": "Bash", "tool_use_id": "t", "tool_input": {"command": "cat big"}, "tool_response": {"stdout": "%s"}}\n' "$big" \
    | vigil_hook
  local file; file=$(find "$VIGIL_ARCHIVE_DIR" -name s3.jsonl)
  [ "$(jq -r .event.tool_response.vigil_truncated "$file")" = "true" ]
  [ "$(jq -r .event.tool_input.command "$file")" = "cat big" ]
  [ "$(wc -c < "$file")" -lt 2200 ]
  local record=("$VIGIL_RECORDS_DIR/proj.1"/*.json)
  [ "$(jq -r .tool_response.vigil_truncated "${record[0]}")" = "true" ]
}

@test "concurrent hooks append whole lines" {
  export COOKED_HOST_SESSION="proj.1"
  local big i; big=$(head -c 200000 /dev/zero | tr '\0' y)
  for i in $(seq 1 8); do
    printf '{"session_id": "s4", "hook_event_name": "PostToolUse", "tool_response": {"stdout": "%s%s"}}\n' "$i" "$big" \
      | vigil_hook &
  done
  wait
  local file; file=$(find "$VIGIL_ARCHIVE_DIR" -name s4.jsonl)
  [ "$(wc -l < "$file")" -eq 8 ]
  jq -e . "$file" >/dev/null
}

# --- vigil-shell ------------------------------------------------------------------

_bash_call() {
  # A Bash tool command as Claude Code hands it to CLAUDE_CODE_SHELL_PREFIX.
  printf "source /nowhere/snapshot.sh 2>/dev/null || true && { shopt -u extglob || setopt NO_EXTENDED_GLOB; } >/dev/null 2>&1 || true && eval '%s' < /dev/null && pwd -P >| %s/cwd" "$1" "$TEST_TEMP"
}

_bash_heredoc_call() {
  # One with a heredoc, which Claude Code hands over without `< /dev/null'.
  printf "source /nowhere/snapshot.sh 2>/dev/null || true && { shopt -u extglob || setopt NO_EXTENDED_GLOB; } >/dev/null 2>&1 || true && eval '%s' && pwd -P >| %s/cwd" "$1" "$TEST_TEMP"
}

_fake_host() {
  # Stands for cooked-host: says how it was called, then runs what it was given.
  cat > "$TEST_TEMP/host" <<'SH'
#!/bin/bash
[ "$1" = run ] || exit 9
shift
while [ "$1" != -- ]; do printf '%s\n' "$1" >> "$FAKE_HOST_LOG"; shift; done
shift
exec "$@"
SH
  chmod +x "$TEST_TEMP/host"
  export COOKED_HOST="$TEST_TEMP/host" FAKE_HOST_LOG="$TEST_TEMP/host.log"
}

@test "vigil-shell runs a Bash tool command through the host, named as the agent wrote it" {
  _fake_host
  export COOKED_HOST_SESSION="proj.1" CLAUDE_CODE_SESSION_ID="conv-1" SHELL=/bin/bash
  run "$BATS_TEST_DIRNAME/../bin/vigil-shell" "$(_bash_call "echo \"it'\\''s here\"; exit 3")"
  [ "$status" -eq 3 ]
  [ "$output" = "it's here" ]
  [ "$(sed -n 1p "$FAKE_HOST_LOG")" = "--label" ]
  [ "$(sed -n 2p "$FAKE_HOST_LOG")" = "echo \"it's here\"; exit 3" ]
  [ "$(sed -n 3p "$FAKE_HOST_LOG")" = "--key" ]
  [ "$(sed -n 4p "$FAKE_HOST_LOG")" = "conv-1" ]
  # And an apostrophe quoted the way Claude Code quotes one.
  rm -f "$FAKE_HOST_LOG"
  run "$BATS_TEST_DIRNAME/../bin/vigil-shell" "$(_bash_call "echo \"it'\"'\"'s here\"")"
  [ "$output" = "it's here" ]
  [ "$(sed -n 2p "$FAKE_HOST_LOG")" = "echo \"it's here\"" ]
}

@test "vigil-shell runs a command with a heredoc through the host too" {
  _fake_host
  export COOKED_HOST_SESSION="proj.1" CLAUDE_CODE_SESSION_ID="conv-1" SHELL=/bin/bash
  command="cat <<'\''EOF'\''
it'\''s here
EOF"
  run "$BATS_TEST_DIRNAME/../bin/vigil-shell" "$(_bash_heredoc_call "$command")"
  [ "$status" -eq 0 ]
  [ "$output" = "it's here" ]
  [ "$(sed -n 2,4p "$FAKE_HOST_LOG")" = "cat <<'EOF'
it's here
EOF" ]
}

@test "vigil-shell leaves a hook's command, and anything not the Bash tool's, alone" {
  _fake_host
  export COOKED_HOST_SESSION="proj.1" SHELL=/bin/bash
  run "$BATS_TEST_DIRNAME/../bin/vigil-shell" "echo a hook; exit 4"
  [ "$status" -eq 4 ]
  [ "$output" = "a hook" ]
  [ ! -e "$FAKE_HOST_LOG" ]
}

@test "vigil-shell is not in the way outside a hosted session or without cooked" {
  _fake_host
  export SHELL=/bin/bash
  run "$BATS_TEST_DIRNAME/../bin/vigil-shell" "$(_bash_call "echo plain; exit 5")"
  [ "$status" -eq 5 ]
  [ "$output" = "plain" ]
  [ ! -e "$FAKE_HOST_LOG" ]
  export COOKED_HOST_SESSION="proj.1" COOKED_HOST="$TEST_TEMP/no-such-host"
  run "$BATS_TEST_DIRNAME/../bin/vigil-shell" "$(_bash_call "echo still; exit 6")"
  [ "$status" -eq 6 ]
  [ "$output" = "still" ]
}

@test "install-shell sets the prefix, keeps the rest, and uninstall-shell takes it out" {
  _write_user_settings
  local before; before=$(jq -cS . "$VIGIL_SETTINGS")
  jq '.env = {"KEEP": "1"}' "$VIGIL_SETTINGS" > "$TEST_TEMP/s" && mv "$TEST_TEMP/s" "$VIGIL_SETTINGS"
  run vigil_hooks install-shell
  [ "$status" -eq 0 ]
  [ "$(jq -r .env.CLAUDE_CODE_SHELL_PREFIX "$VIGIL_SETTINGS")" = "$(cd "$BATS_TEST_DIRNAME/../bin" && pwd -P)/vigil-shell" ]
  [ "$(jq -r .env.KEEP "$VIGIL_SETTINGS")" = "1" ]
  # And the one directory a sandboxed command must be able to write in, made
  # for its owner only.
  [ "$(jq -c .sandbox.filesystem.allowWrite "$VIGIL_SETTINGS")" = "[\"$TEST_TEMP/runs\"]" ]
  [ -d "$TEST_TEMP/runs" ]
  [ -z "$(find "$TEST_TEMP/runs" -maxdepth 0 -perm +077)" ]
  [ "$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$VIGIL_SETTINGS")" = "my-linter" ]
  run vigil_hooks install-shell
  [[ "$output" == *"Nothing to change"* ]]
  run vigil_hooks uninstall-shell
  [ "$status" -eq 0 ]
  [ "$(jq -c .env "$VIGIL_SETTINGS")" = '{"KEEP":"1"}' ]
  [ "$(jq -r .sandbox "$VIGIL_SETTINGS")" = "null" ]
}

@test "install-shell keeps the sandbox settings that are there, and uninstall-shell too" {
  mkdir -p "$HOME/.claude"
  echo '{"sandbox": {"enabled": true, "filesystem": {"allowWrite": ["~/.kube"]}}}' > "$VIGIL_SETTINGS"
  vigil_hooks install-shell >/dev/null
  [ "$(jq -r .sandbox.enabled "$VIGIL_SETTINGS")" = "true" ]
  [ "$(jq -c .sandbox.filesystem.allowWrite "$VIGIL_SETTINGS")" = "[\"~/.kube\",\"$TEST_TEMP/runs\"]" ]
  vigil_hooks install-shell --dry-run | grep -q "Nothing to change"
  vigil_hooks uninstall-shell >/dev/null
  [ "$(jq -c .sandbox "$VIGIL_SETTINGS")" = '{"enabled":true,"filesystem":{"allowWrite":["~/.kube"]}}' ]
}

@test "the hook says whether the agent's commands go through vigil-shell" {
  export COOKED_HOST_SESSION="proj.1"
  _tool_event toolu_1 | vigil_hook
  [ ! -e "$VIGIL_RECORDS_DIR/proj.1/.shell" ]
  export CLAUDE_CODE_SHELL_PREFIX="/somewhere/bin/vigil-shell"
  _tool_event toolu_2 | vigil_hook
  [ -e "$VIGIL_RECORDS_DIR/proj.1/.shell" ]
  export CLAUDE_CODE_SHELL_PREFIX="/usr/local/bin/their-logger"
  _tool_event toolu_3 | vigil_hook
  [ ! -e "$VIGIL_RECORDS_DIR/proj.1/.shell" ]
  local files=("$VIGIL_RECORDS_DIR/proj.1"/*.json)
  [ "${#files[@]}" -eq 3 ]
}

@test "install-shell leaves a prefix that is somebody else's alone" {
  mkdir -p "$HOME/.claude"
  echo '{"env": {"CLAUDE_CODE_SHELL_PREFIX": "/usr/local/bin/their-logger"}}' > "$VIGIL_SETTINGS"
  local before; before=$(cat "$VIGIL_SETTINGS")
  run vigil_hooks install-shell
  [ "$status" -ne 0 ]
  [[ "$output" == *"not vigil's"* ]]
  run vigil_hooks uninstall-shell
  [ "$status" -ne 0 ]
  [ "$(cat "$VIGIL_SETTINGS")" = "$before" ]
}
