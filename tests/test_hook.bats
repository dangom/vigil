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
  unset VIGIL_EVENT_TIME VIGIL_BIN PI_CODING_AGENT_DIR
  export VIGIL_PI_EXTENSIONS="$HOME/.pi/agent/extensions"
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

# Fail if the command succeeds.  A bare `! command' fails no test unless it is
# the test's last line.
refute() {
  if "$@"; then
    echo "succeeded, and should not have: $*"
    return 1
  fi
}

# $1 itself, if anyone but its owner may read, write or enter it.
_open_to_others() {
  find "$1" -maxdepth 0 \( -perm -040 -o -perm -020 -o -perm -010 \
                           -o -perm -004 -o -perm -002 -o -perm -001 \)
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
    [ -z "$(_open_to_others "$file")" ] || { echo "open to others: $file"; return 1; }
  done < <(find "$VIGIL_DATA_DIR")
  [ -n "$(find "$VIGIL_ARCHIVE_DIR" -name s.jsonl)" ]
}

@test "nothing in vigil opens a connection" {
  # No program that talks to another machine is named anywhere in it.
  refute grep -nEw 'curl|wget|nc|ncat|netcat|ssh|scp|sftp|rsync|ftp|telnet|socat|urllib|requests|socket|http|https' \
      "$BATS_TEST_DIRNAME/../bin/vigil" "$BATS_TEST_DIRNAME/../bin/vigil-shell" \
      "$BATS_TEST_DIRNAME/../coverage/python/sitecustomize.py"
  refute grep -nEw 'fetch|http|https|net|tls|dgram|WebSocket|XMLHttpRequest' \
      "$BATS_TEST_DIRNAME/../pi/vigil.ts" "$BATS_TEST_DIRNAME/../coverage/node/vigil-coverage.cjs"
  refute grep -nE 'url-retrieve|make-network-process|open-network-stream|url-copy-file|url-http' \
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
  for event in PostToolUse PostToolUseFailure SubagentStart SubagentStop SessionStart UserPromptSubmit; do
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
  refute ls "$VIGIL_SETTINGS".vigil-backup-* >/dev/null 2>&1
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
  [ -z "$(_open_to_others "$TEST_TEMP/runs")" ]
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

# --- pi ---------------------------------------------------------------------------

@test "a reporter's own time for an event names its record, and nothing else does" {
  export COOKED_HOST_SESSION="proj.1"
  _tool_event toolu_1 | VIGIL_EVENT_TIME=1700000000.250000 vigil_hook
  ls "$VIGIL_RECORDS_DIR/proj.1"/1700000000.250000-*.json >/dev/null
  _tool_event toolu_2 | VIGIL_EVENT_TIME='../../x' vigil_hook
  local files=("$VIGIL_RECORDS_DIR/proj.1"/*.json)
  [ "${#files[@]}" -eq 2 ]
  [ -z "$(find "$TEST_TEMP" -name 'x*')" ]
}

@test "install-hooks --agent pi copies the extension, once, and uninstall removes it" {
  run vigil_hooks install --agent pi --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Would copy"* ]]
  [ ! -e "$VIGIL_PI_EXTENSIONS/vigil.ts" ]
  run vigil_hooks install --agent pi
  [ "$status" -eq 0 ]
  cmp "$BATS_TEST_DIRNAME/../pi/vigil.ts" "$VIGIL_PI_EXTENSIONS/vigil.ts"
  run vigil_hooks install --agent pi
  [[ "$output" == *"Nothing to change"* ]]
  # Claude Code's settings are not this agent's.
  [ ! -e "$VIGIL_SETTINGS" ]
  run vigil_hooks uninstall --agent pi --dry-run
  [ -e "$VIGIL_PI_EXTENSIONS/vigil.ts" ]
  run vigil_hooks uninstall --agent pi
  [ "$status" -eq 0 ]
  [ ! -e "$VIGIL_PI_EXTENSIONS/vigil.ts" ]
}

@test "install-hooks --agent pi brings an older copy of the extension up to date" {
  mkdir -p "$VIGIL_PI_EXTENSIONS"
  { head -n 1 "$BATS_TEST_DIRNAME/../pi/vigil.ts"; echo "// older"; } > "$VIGIL_PI_EXTENSIONS/vigil.ts"
  run vigil_hooks install --agent pi --dry-run
  [[ "$output" == *"-// older"* ]]
  run vigil_hooks install --agent pi
  cmp "$BATS_TEST_DIRNAME/../pi/vigil.ts" "$VIGIL_PI_EXTENSIONS/vigil.ts"
}

@test "install-hooks --agent pi leaves a vigil.ts that is somebody else's alone" {
  mkdir -p "$VIGIL_PI_EXTENSIONS"
  echo "// mine" > "$VIGIL_PI_EXTENSIONS/vigil.ts"
  run vigil_hooks install --agent pi
  [ "$status" -ne 0 ]
  [[ "$output" == *"not vigil's"* ]]
  run vigil_hooks uninstall --agent pi
  [ "$status" -ne 0 ]
  [ "$(cat "$VIGIL_PI_EXTENSIONS/vigil.ts")" = "// mine" ]
}

@test "an agent nobody knows, and pi's shell, are refused" {
  run vigil_hooks install --agent emacs
  [ "$status" -ne 0 ]
  run vigil_hooks install-shell --agent pi
  [ "$status" -ne 0 ]
  [ ! -e "$VIGIL_SETTINGS" ]
}

# pi's events, fired at the extension by node; the hook it starts is the real one.
_pi_events() {
  mkdir -p "$TEST_TEMP/work"
  # $1, where it is given, stands in for vigil.
  env -u VIGIL_TESTING VIGIL_BIN="${1:-$BATS_TEST_DIRNAME/../bin/vigil}" \
      node "$BATS_TEST_DIRNAME/pi-events.mjs" "$BATS_TEST_DIRNAME/../pi/vigil.ts" "$TEST_TEMP/work"
}

# Wait for $1 records under the session proj.1: the hooks outlive the extension.
_pi_records() {
  local n=0 files
  while [ "$n" -lt 100 ]; do
    files=("$VIGIL_RECORDS_DIR/proj.1"/*.json)
    [ -e "${files[0]}" ] && [ "${#files[@]}" -ge "$1" ] && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}

@test "pi's extension hands the hook each event, in order, under the hook's names" {
  node -e 'process.exit(process.features.typescript ? 0 : 1)' 2>/dev/null || skip "node cannot run TypeScript"
  export COOKED_HOST_SESSION="proj.1"
  _pi_events
  _pi_records 7
  sleep 0.3
  local files=("$VIGIL_RECORDS_DIR/proj.1"/*.json)
  [ "${#files[@]}" -eq 7 ]
  local names; names=$(jq -r .hook_event_name "${files[@]}" | paste -sd, -)
  [ "$names" = "SessionStart,UserPromptSubmit,PreToolUse,PostToolUse,PreToolUse,PostToolUse,Stop" ]
  # The archive has them in the same order: they were handed over one by one.
  [ "$(jq -r .event.hook_event_name "$VIGIL_ARCHIVE_DIR"/*/*/pi-session-1.jsonl | paste -sd, -)" = "$names" ]
  [ "$(jq -r '[.agent, .session_id, .model, .source] | join(" ")' "${files[0]}")" = "pi pi-session-1 ollama/flint startup" ]
  [ "$(jq -r .prompt "${files[1]}")" = "fix notes.txt" ]
  [ "$(jq -r .event.prompt "$VIGIL_PROMPT_HISTORY")" = "fix notes.txt" ]
  # A call, as pi gave it, with what pi does not say: the context, the file before.
  [ "$(jq -r '[.tool_name, .tool_use_id, .tool_input.path, .context_tokens] | join(" ")' "${files[2]}")" = "edit c1 notes.txt 1100" ]
  [ "$(jq -r .tool_response.details.patch "${files[3]}" | head -n 1)" = "--- notes.txt" ]
  [ "$(jq -r .original_file "${files[3]}")" = $'alpha\nbeta\ngamma' ]
  [ "$(jq -r '[.tool_input.edits[0].oldText, .duration_ms, .is_error] | join(" ")' "${files[3]}")" = "beta 3 false" ]
  [ "$(jq -r '[.created, .original_file] | join(" ")' "${files[5]}")" = "true " ]
  # The reply is the model's words, without its thinking.
  [ "$(jq -r .last_assistant_message "${files[6]}")" = "Fixed." ]
}

@test "pi's extension starts nothing outside a hosted session" {
  node -e 'process.exit(process.features.typescript ? 0 : 1)' 2>/dev/null || skip "node cannot run TypeScript"
  # In vigil's place, something that says it was started.
  printf '#!/bin/sh\ncat > /dev/null\necho "$1" >> "%s/started"\n' "$TEST_TEMP" > "$TEST_TEMP/stub"
  chmod +x "$TEST_TEMP/stub"
  _pi_events "$TEST_TEMP/stub"
  sleep 0.5
  [ ! -e "$TEST_TEMP/started" ]
  [ ! -d "$VIGIL_DATA_DIR" ]
  # Hosted, the same stand-in is started for every report.
  export COOKED_HOST_SESSION="proj.1"
  _pi_events "$TEST_TEMP/stub"
  sleep 0.5
  [ "$(sort -u "$TEST_TEMP/started")" = "hook" ]
}

@test "pi's extension keeps a snapshot before the agent begins, and one when it settles, as pi's" {
  node -e 'process.exit(process.features.typescript ? 0 : 1)' 2>/dev/null || skip "node cannot run TypeScript"
  export COOKED_HOST_SESSION="proj.1" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
  mkdir -p "$TEST_TEMP/work" && git -C "$TEST_TEMP/work" init -q -b main
  # Off, nothing is kept.
  _pi_events
  refute git -C "$TEST_TEMP/work" rev-parse -q --verify "$VIGIL_SNAPSHOT_REF"
  command rm -f "$TEST_TEMP/work/after-prompt.txt"
  mkdir -p "$VIGIL_DATA_DIR" && : > "$VIGIL_DATA_DIR/snapshots-on"
  _pi_events
  local n=0
  while [ "$n" -lt 100 ] \
      && [ "$(git -C "$TEST_TEMP/work" log -g --format=%H "$VIGIL_SNAPSHOT_REF" 2>/dev/null | wc -l)" -lt 2 ]; do
    sleep 0.1; n=$((n + 1))
  done
  cd "$TEST_TEMP/work"
  local subjects; subjects=$(git log -g --format=%s "$VIGIL_SNAPSHOT_REF")
  local first second
  second=$(echo "$subjects" | sed -n 1p); first=$(echo "$subjects" | sed -n 2p)
  [[ "$first" =~ ^vigil\ UserPromptSubmit\ pi-session-1\ ([0-9a-f-]{36})\ proj\.1\ pi$ ]]
  local prompt="${BASH_REMATCH[1]}"
  [ "$second" = "vigil Stop pi-session-1 $prompt proj.1 pi" ]
  # The one at the prompt was kept before the agent went on.
  local before after
  after=$(git log -g --format=%H "$VIGIL_SNAPSHOT_REF" | sed -n 1p)
  before=$(git log -g --format=%H "$VIGIL_SNAPSHOT_REF" | sed -n 2p)
  [ "$(git ls-tree -r --name-only "$before" | tr '\n' ' ')" = "notes.txt " ]
  [ "$(git ls-tree -r --name-only "$after" | tr '\n' ' ')" = "after-prompt.txt notes.txt " ]
  # The reports are handed over without anything waiting for them, and the
  # last of them in no order: pi was going.  Every report from the prompt on
  # says which prompt it is of; the session's start, before any, says none.
  local of_prompt= n=0
  while [ "$n" -lt 100 ]; do
    of_prompt=$(jq -r --arg p "$prompt" 'select(.event.prompt_id == $p) | .event.hook_event_name' \
                  "$VIGIL_ARCHIVE_DIR"/*/*/pi-session-1.jsonl 2>/dev/null | sort | paste -sd, -)
    [ "$of_prompt" = "PostToolUse,PostToolUse,PreToolUse,PreToolUse,Stop,UserPromptSubmit" ] && break
    sleep 0.1; n=$((n + 1))
  done
  [ "$of_prompt" = "PostToolUse,PostToolUse,PreToolUse,PreToolUse,Stop,UserPromptSubmit" ]
  [ "$(jq -r 'select(.event.hook_event_name == "SessionStart") | .event.prompt_id // "none"' \
         "$VIGIL_ARCHIVE_DIR"/*/*/pi-session-1.jsonl | sort -u)" = "none" ]
}

# --- coverage ----------------------------------------------------------------------

_project() {
  # A repository with a Python and a Node program in it, each calling one of
  # two functions.
  mkdir -p "$TEST_TEMP/proj/pkg" "$TEST_TEMP/proj/node_modules/dep"
  ( cd "$TEST_TEMP/proj" && git init -q ) || return 1
  printf 'def used():\n    return 1\n\n\ndef unused():\n    return 2\n' > "$TEST_TEMP/proj/pkg/lib.py"
  : > "$TEST_TEMP/proj/pkg/__init__.py"
  printf 'from pkg.lib import used\nprint(used())\n' > "$TEST_TEMP/proj/main.py"
  printf 'function used() { return 1 }\nfunction unused() { return 2 }\nmodule.exports = { used, unused }\n' > "$TEST_TEMP/proj/lib.js"
  printf 'module.exports = { dep() { return 3 } }\n' > "$TEST_TEMP/proj/node_modules/dep/index.js"
  printf 'const { used } = require("./lib.js"); console.log(used() + require("dep").dep())\n' > "$TEST_TEMP/proj/main.js"
}

_new_python() {
  # A Python with sys.monitoring: 3.12 or later.
  local python
  for python in python3 python3.14 python3.13 python3.12; do
    if "$python" -c 'import sys; sys.exit(0 if hasattr(sys, "monitoring") else 1)' 2>/dev/null; then
      command -v "$python"
      return 0
    fi
  done
  return 1
}

@test "vigil-shell says nothing of coverage unless it is on" {
  export SHELL=/bin/bash
  unset VIGIL_COVERAGE PYTHONPATH NODE_OPTIONS
  run "$BATS_TEST_DIRNAME/../bin/vigil-shell" \
      "$(_bash_call 'echo "[${VIGIL_COVERAGE_RUN:-}][${PYTHONPATH:-}][${NODE_OPTIONS:-}]"')"
  [ "$status" -eq 0 ]
  [ "$output" = "[][][]" ]
  # Nor of anything that is not the Bash tool's.
  export VIGIL_COVERAGE=1
  run "$BATS_TEST_DIRNAME/../bin/vigil-shell" 'echo "[${VIGIL_COVERAGE_RUN:-}]"'
  [ "$output" = "[]" ]
  # The file says on; the variable says off, and wins.
  : > "$VIGIL_DATA_DIR/coverage-on" 2>/dev/null || { mkdir -p "$VIGIL_DATA_DIR"; : > "$VIGIL_DATA_DIR/coverage-on"; }
  export VIGIL_COVERAGE=0
  run "$BATS_TEST_DIRNAME/../bin/vigil-shell" "$(_bash_call 'echo "[${VIGIL_COVERAGE_RUN:-}]"')"
  [ "$output" = "[]" ]
  [ ! -d "$VIGIL_DATA_DIR/coverage" ]
}

@test "vigil-shell, with coverage on, tells Python and Node where to write, and makes nothing itself" {
  export SHELL=/bin/bash PYTHONPATH=/mine NODE_OPTIONS=--no-warnings CLAUDE_CODE_SESSION_ID="conv 1"
  mkdir -p "$VIGIL_DATA_DIR" && : > "$VIGIL_DATA_DIR/coverage-on"
  unset VIGIL_COVERAGE
  run "$BATS_TEST_DIRNAME/../bin/vigil-shell" \
      "$(_bash_call 'echo "$VIGIL_COVERAGE_RUN"; echo "$PYTHONPATH"; echo "$NODE_OPTIONS"; echo "$VIGIL_COVERAGE_COMMAND"; echo "$VIGIL_COVERAGE_CWD"; exit 7')"
  [ "$status" -eq 7 ]
  local coverage="$BATS_TEST_DIRNAME/../bin/../coverage"
  # Named for the session, when and which: a session's name made a file's.
  [[ "${lines[0]}" =~ ^"$VIGIL_DATA_DIR"/coverage/conv_1/[0-9]+-[0-9]+$ ]]
  # In front of what was there, which is kept.
  [ "${lines[1]}" = "$coverage/python:/mine" ]
  [ "${lines[2]}" = "--require $coverage/node/vigil-coverage.cjs --no-warnings" ]
  [[ "${lines[3]}" == 'echo "$VIGIL_COVERAGE_RUN"; echo "$PYTHONPATH"'* ]]
  [ "${lines[4]}" = "$PWD" ]
  # A command that ran no Python and no Node left nothing behind.
  [ ! -d "$VIGIL_DATA_DIR/coverage" ]
}

@test "with coverage on, a Python program's functions that ran are kept, and only the project's" {
  local python
  python=$(_new_python) || skip "no Python with sys.monitoring (3.12 or later)"
  _project
  export SHELL=/bin/bash VIGIL_COVERAGE=1 VIGIL_SESSION=proj.1
  unset PYTHONPATH
  cd "$TEST_TEMP/proj"
  run "$BATS_TEST_DIRNAME/../bin/vigil-shell" "$(_bash_call "$python main.py")"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
  local dir
  dir=$(echo "$VIGIL_DATA_DIR"/coverage/proj.1/*)
  [ "$(cat "$dir/command.txt")" = "$python main.py" ]
  [ "$(cd "$(cat "$dir/cwd.txt")" && pwd -P)" = "$(pwd -P)" ]
  local root
  root=$(pwd -P)
  [ "$(jq -c --arg root "$root/" '.files | with_entries(.key |= ltrimstr($root))' "$dir"/python-*.json)" \
    = '{"main.py":["<module>"],"pkg/__init__.py":["<module>"],"pkg/lib.py":["<module>","used"]}' ]
}

@test "the Python hook does nothing on an old Python, and is never why a program fails" {
  _project
  cd "$TEST_TEMP/proj"
  # No leave to write where it is told to: the program runs all the same.
  mkdir "$TEST_TEMP/shut" && chmod 500 "$TEST_TEMP/shut"
  local python
  for python in python3 $(_new_python || true); do
    command -v "$python" >/dev/null || continue
    run env VIGIL_COVERAGE_RUN="$TEST_TEMP/shut/run" \
        PYTHONPATH="$BATS_TEST_DIRNAME/../coverage/python" "$python" main.py
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
  done
  # A sitecustomize of the project's own, behind vigil's, still runs.
  mkdir "$TEST_TEMP/site" && echo 'print("theirs")' > "$TEST_TEMP/site/sitecustomize.py"
  run env PYTHONPATH="$BATS_TEST_DIRNAME/../coverage/python:$TEST_TEMP/site" python3 main.py
  [ "$status" -eq 0 ]
  [ "$output" = $'theirs\n1' ]
}

@test "with coverage on, a Node program's functions that ran are kept, and only the project's" {
  command -v node >/dev/null || skip "no node"
  _project
  export SHELL=/bin/bash VIGIL_COVERAGE=1 VIGIL_SESSION=proj.1
  unset NODE_OPTIONS
  cd "$TEST_TEMP/proj"
  run "$BATS_TEST_DIRNAME/../bin/vigil-shell" "$(_bash_call "node main.js")"
  [ "$status" -eq 0 ]
  [ "$output" = "4" ]
  local dir root
  dir=$(echo "$VIGIL_DATA_DIR"/coverage/proj.1/*)
  root=$(pwd -P)
  [ "$(cat "$dir/command.txt")" = "node main.js" ]
  [ "$(jq -c --arg root "$root/" '.files | with_entries(.key |= ltrimstr($root))' "$dir"/node-*.json)" \
    = '{"main.js":[],"lib.js":["used"]}' ]
  # Never why a program fails: nowhere to write, and it runs all the same.
  mkdir "$TEST_TEMP/shut" && chmod 500 "$TEST_TEMP/shut"
  run env VIGIL_COVERAGE_RUN="$TEST_TEMP/shut/run" \
      NODE_OPTIONS="--require $BATS_TEST_DIRNAME/../coverage/node/vigil-coverage.cjs" node main.js
  [ "$status" -eq 0 ]
  [ "$output" = "4" ]
}

@test "coverage on lets the sandbox write the one directory, and off takes that back" {
  mkdir -p "$HOME/.claude"
  echo '{"model": "opus", "sandbox": {"filesystem": {"allowWrite": ["/elsewhere"]}}}' > "$VIGIL_SETTINGS"
  run vigil_coverage status
  [[ "$output" == "Coverage is off."* ]]
  run vigil_coverage on --dry-run
  [ "$status" -eq 0 ]
  [ ! -e "$VIGIL_DATA_DIR/coverage-on" ]
  [ "$(jq -c .sandbox.filesystem.allowWrite "$VIGIL_SETTINGS")" = '["/elsewhere"]' ]
  run vigil_coverage on
  [ "$status" -eq 0 ]
  [ -e "$VIGIL_DATA_DIR/coverage-on" ]
  [ -d "$VIGIL_DATA_DIR/coverage" ]
  [ "$(jq -c .sandbox.filesystem.allowWrite "$VIGIL_SETTINGS")" = "[\"/elsewhere\",\"$VIGIL_DATA_DIR/coverage\"]" ]
  [ "$(jq -r .model "$VIGIL_SETTINGS")" = "opus" ]
  run vigil_coverage status
  [[ "$output" == "Coverage is on."* ]]
  # Twice is once.
  run vigil_coverage on
  [ "$(jq -c '.sandbox.filesystem.allowWrite | length' "$VIGIL_SETTINGS")" = "2" ]
  run vigil_coverage off
  [ "$status" -eq 0 ]
  [ ! -e "$VIGIL_DATA_DIR/coverage-on" ]
  [ "$(jq -c .sandbox.filesystem.allowWrite "$VIGIL_SETTINGS")" = '["/elsewhere"]' ]
}

# --- snapshots ---------------------------------------------------------------------

_repository() {
  # A repository with one commit; then a tracked file changed, a file git does
  # not track, one it ignores, and one too big to keep.
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
  mkdir -p "$TEST_TEMP/repo/sub" && cd "$TEST_TEMP/repo" || return 1
  git init -q -b main
  echo one > tracked; echo ignored > .gitignore
  git add -A && git -c user.name=T -c user.email=t@example.org commit -q -m one
  echo two > tracked
  echo new > sub/untracked
  echo no > ignored
  head -c 4096 /dev/zero > big
  export VIGIL_SNAPSHOT_MAX=1024
}

_snapshot_event() {
  # $1 the event, $2 the prompt's id, $3 where.
  printf '{"hook_event_name":"%s","session_id":"s-1","prompt_id":"%s","cwd":"%s","prompt":"a \\"cwd\\":\\"/elsewhere\\""}' \
    "$1" "$2" "$3"
}

_state() {
  # Everything of the repository a snapshot must leave as it was.
  git status --porcelain --ignored; git rev-parse HEAD; git stash list
  git for-each-ref --format='%(refname) %(objectname)' refs/heads refs/tags
  shasum .git/index
}

@test "a snapshot keeps the files as they are, and leaves the repository as it was" {
  _repository
  local before commit
  before=$(_state)
  commit=$(vigil_snapshot_take "$TEST_TEMP/repo/sub" View)
  [ -n "$commit" ]
  [ "$(_state)" = "$before" ]
  [ "$(git rev-parse "$VIGIL_SNAPSHOT_REF")" = "$commit" ]
  # Tracked files as they are in the working tree; untracked ones; not what
  # is ignored, nor what is over the size.
  [ "$(git ls-tree -r --name-only "$commit" | tr '\n' ' ')" = ".gitignore sub/untracked tracked " ]
  [ "$(git show "$commit:tracked")" = "two" ]
  [ "$(git log -1 --format=%s "$commit")" = "vigil View - - - -" ]
  # No parent: it is not part of anybody's history.
  [ -z "$(git log -1 --format=%P "$commit")" ]
}

@test "a repository with nothing committed or staged yet is kept too" {
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
  mkdir -p "$TEST_TEMP/fresh" && cd "$TEST_TEMP/fresh" && git init -q -b main
  local a b
  a=$(vigil_snapshot_take . View)
  [ -n "$a" ]
  [ -z "$(git ls-tree -r --name-only "$a")" ]
  echo first > file
  b=$(vigil_snapshot_take . View)
  [ "$(git diff --name-status "$a" "$b" | tr '\t\n' '  ')" = "A file " ]
  # Still nothing staged, and nothing committed.
  [ "$(git status --porcelain)" = "?? file" ]
  refute git rev-parse -q --verify HEAD
}

@test "two snapshots are a diff, and the ones before the newest are kept" {
  _repository
  local a b
  a=$(vigil_snapshot_take . View)
  echo three > tracked; command rm -f sub/untracked; echo more > added
  b=$(vigil_snapshot_take . View)
  [ "$(git diff --name-status "$a" "$b" | tr '\t\n' '  ')" = "A added D sub/untracked M tracked " ]
  [ "$(git log -g --format=%H "$VIGIL_SNAPSHOT_REF" | tr '\n' ' ')" = "$b $a " ]
  # Nothing changed: the same tree again.
  local c
  c=$(vigil_snapshot_take . Stop)
  [ "$c" != "$b" ]
  [ "$(git rev-parse "$c^{tree}")" = "$(git rev-parse "$b^{tree}")" ]
}

@test "the snapshot hook says which prompt it was for, prints nothing and never fails" {
  _repository
  export COOKED_HOST_SESSION="proj.1"
  run env -u VIGIL_TESTING bash -c "$(declare -f _snapshot_event); _snapshot_event UserPromptSubmit p-1 '$TEST_TEMP/repo' | '$BATS_TEST_DIRNAME/../bin/vigil' snapshot"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(git log -1 --format=%s "$VIGIL_SNAPSHOT_REF")" = "vigil UserPromptSubmit s-1 p-1 proj.1 claude" ]
  # A subagent's prompt, somewhere that is no repository, a report that is
  # not JSON, and snapshots turned off: nothing, and no failure.
  local kept; kept=$(git rev-parse "$VIGIL_SNAPSHOT_REF")
  printf '{"hook_event_name":"UserPromptSubmit","agent_id":"a1","cwd":"%s"}' "$TEST_TEMP/repo" | vigil_snapshot
  _snapshot_event Stop p-1 "$TEST_TEMP" | vigil_snapshot
  echo 'not json' | vigil_snapshot
  _snapshot_event Stop p-1 "$TEST_TEMP/repo" | VIGIL_SNAPSHOTS=0 vigil_snapshot
  [ "$(git rev-parse "$VIGIL_SNAPSHOT_REF")" = "$kept" ]
  # And a repository that wants none has none.
  git config vigil.snapshots false
  _snapshot_event Stop p-1 "$TEST_TEMP/repo" | vigil_snapshot
  [ "$(git rev-parse "$VIGIL_SNAPSHOT_REF")" = "$kept" ]
}

@test "a snapshot survives what a killed one left behind, and a working tree has its own" {
  _repository
  local a b
  a=$(vigil_snapshot_take . View)
  # Killed while it held the index's lock.
  : > .git/vigil-index.lock
  echo four > tracked
  b=$(vigil_snapshot_take . View)
  [ "$(git show "$b:tracked")" = "four" ]
  # Its index made unusable: begun again.
  echo garbage > .git/vigil-index
  b=$(vigil_snapshot_take . View)
  [ "$(git show "$b:tracked")" = "four" ]
  [ "$(git ls-tree -r --name-only "$b" | tr '\n' ' ')" = ".gitignore sub/untracked tracked " ]
  # Another working tree of the same repository keeps its own.
  git worktree add -q "$TEST_TEMP/other" -b other HEAD
  echo elsewhere > "$TEST_TEMP/other/tracked"
  local c; c=$(vigil_snapshot_take "$TEST_TEMP/other" View)
  [ "$(git show "$c:tracked")" = "elsewhere" ]
  [ "$(git rev-parse "$VIGIL_SNAPSHOT_REF")" = "$b" ]
  [ "$(git -C "$TEST_TEMP/other" rev-parse "$VIGIL_SNAPSHOT_REF")" = "$c" ]
  # Forgetting takes the ref and vigil's index away, and nothing else.
  run vigil_snapshots forget "$TEST_TEMP/repo"
  [ "$status" -eq 0 ]
  refute git rev-parse -q --verify "$VIGIL_SNAPSHOT_REF"
  [ ! -e .git/vigil-index ]
  [ "$(git show HEAD:tracked)" = "one" ]
}

@test "snapshots on puts a hook that is waited for on prompts and stops, and off takes it out" {
  mkdir -p "$(dirname "$VIGIL_SETTINGS")"
  echo '{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "mine"}]}]}}' > "$VIGIL_SETTINGS"
  vigil_hooks install >/dev/null
  run vigil_snapshots status
  [[ "$output" == *"Snapshots are off."* ]]
  run vigil_snapshots on --dry-run
  refute grep -q '"vigil snapshot"' "$VIGIL_SETTINGS"
  run vigil_snapshots on
  [ "$status" -eq 0 ]
  [ "$(jq -c '.hooks.UserPromptSubmit | map(.hooks[0] | [.command, .async, .timeout])' "$VIGIL_SETTINGS")" \
    = '[["vigil hook",true,null],["vigil snapshot",null,10]]' ]
  [ "$(jq -c '.hooks.Stop | map(.hooks[0].command)' "$VIGIL_SETTINGS")" = '["mine","vigil hook","vigil snapshot"]' ]
  # And around each command, failed or not: for Bash alone, and waited for.
  [ "$(jq -c '.hooks.PreToolUse | map([.matcher, .hooks[0].command, .hooks[0].async])' "$VIGIL_SETTINGS")" \
    = '[[null,"vigil hook",true],["Bash","vigil snapshot",null]]' ]
  [ "$(jq -c '.hooks.PostToolUse | map([.matcher, .hooks[0].command])' "$VIGIL_SETTINGS")" \
    = '[[null,"vigil hook"],["Bash","vigil snapshot"]]' ]
  [ "$(jq -c '.hooks.PostToolUseFailure | map([.matcher, .hooks[0].command, .hooks[0].timeout])' "$VIGIL_SETTINGS")" \
    = '[[null,"vigil hook",null],["Bash","vigil snapshot",10]]' ]
  run vigil_snapshots status
  [[ "$output" == *"Snapshots are on."* ]]
  [ -e "$VIGIL_DATA_DIR/snapshots-on" ]
  # Twice is once; and the other hook's coming and going leaves it alone.
  vigil_snapshots on >/dev/null
  [ "$(jq -c '.hooks.PreToolUse | length' "$VIGIL_SETTINGS")" = 2 ]
  vigil_hooks uninstall >/dev/null
  [ "$(jq -c '.hooks.Stop | map(.hooks[0].command)' "$VIGIL_SETTINGS")" = '["mine","vigil snapshot"]' ]
  vigil_hooks install >/dev/null
  run vigil_snapshots off
  [ "$status" -eq 0 ]
  [ "$(jq -c '.hooks.Stop | map(.hooks[0].command)' "$VIGIL_SETTINGS")" = '["mine","vigil hook"]' ]
  [ "$(jq -c '.hooks.UserPromptSubmit | map(.hooks[0].command)' "$VIGIL_SETTINGS")" = '["vigil hook"]' ]
  [ "$(jq -c '.hooks.PreToolUse | map(.hooks[0].command)' "$VIGIL_SETTINGS")" = '["vigil hook"]' ]
  [ "$(jq -c '.hooks.PostToolUseFailure | map(.hooks[0].command)' "$VIGIL_SETTINGS")" = '["vigil hook"]' ]
  [ ! -e "$VIGIL_DATA_DIR/snapshots-on" ]
}

@test "pi's extension keeps what a command changed, before pi goes on" {
  node -e 'process.exit(process.features.typescript ? 0 : 1)' 2>/dev/null || skip "node cannot run TypeScript"
  export COOKED_HOST_SESSION="proj.1" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
  mkdir -p "$TEST_TEMP/work" && git -C "$TEST_TEMP/work" init -q -b main
  mkdir -p "$VIGIL_DATA_DIR" && : > "$VIGIL_DATA_DIR/snapshots-on"
  PI_EVENTS_COMMAND=1 _pi_events
  cd "$TEST_TEMP/work"
  local n=0
  while [ "$n" -lt 100 ] && ! git log -g --format=%s "$VIGIL_SNAPSHOT_REF" 2>/dev/null | grep -q '^vigil Stop'; do
    sleep 0.1; n=$((n + 1))
  done
  # Before the command: what the agent's edit and write had changed since the
  # prompt.  After it: the one file the command changed.
  local before after
  before=$(git log -g --format='%H %s' "$VIGIL_SNAPSHOT_REF" | awk '$3 == "PreToolUse" && $8 == "c3" {print $1}')
  after=$(git log -g --format='%H %s' "$VIGIL_SNAPSHOT_REF" | awk '$3 == "PostToolUse" && $8 == "c3" {print $1}')
  [ -n "$before" ] && [ -n "$after" ]
  [ "$(git log -1 --format=%s "$after" | awk '{print $6, $8}')" = "pi $before" ]
  [ "$(git diff --name-only "$before" "$after")" = "notes.txt" ]
  [ "$(git show "$after:notes.txt" | head -1)" = "ALPHA" ]
}

@test "setup puts everything in place at once, and doctor says what is and is not" {
  mkdir -p "$(dirname "$VIGIL_SETTINGS")"
  echo '{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "mine"}]}]}}' > "$VIGIL_SETTINGS"
  # Before: nothing of vigil's, and for each thing the command that puts it there.
  run vigil_doctor
  [ "$status" -eq 0 ]
  [[ "$output" =~ off\ +records:[^$'\n']+vigil\ install-hooks ]]
  [[ "$output" =~ off\ +snapshots\ around\ each\ command\ +vigil\ snapshots\ on ]]
  [[ "$output" =~ off\ +commands\ followed\ as\ they\ run\ +vigil\ install-shell ]]
  # Doctor only reads; and a dry run of setup changes nothing either.
  local before; before=$(cat "$VIGIL_SETTINGS")
  run vigil_setup --dry-run
  [ "$status" -eq 0 ]
  [ "$(cat "$VIGIL_SETTINGS")" = "$before" ]
  [ ! -e "$VIGIL_DATA_DIR/snapshots-on" ]
  run vigil_setup
  [ "$status" -eq 0 ]
  [[ "$output" =~ on\ +records: ]]
  [[ "$output" =~ on\ +snapshots\ when\ a\ prompt\ is\ given ]]
  [[ "$output" =~ on\ +snapshots\ around\ each\ command ]]
  [[ "$output" =~ off\ +commands\ followed ]]
  [ "$(jq -c '.hooks.Stop | map(.hooks[0].command)' "$VIGIL_SETTINGS")" = '["mine","vigil hook","vigil snapshot"]' ]
  [ "$(jq -r '.env.CLAUDE_CODE_SHELL_PREFIX // "none"' "$VIGIL_SETTINGS")" = none ]
  # Twice is once.
  before=$(cat "$VIGIL_SETTINGS")
  vigil_setup >/dev/null
  [ "$(cat "$VIGIL_SETTINGS")" = "$before" ]
  # Snapshots from before there were any around commands: said to be partly on.
  jq 'del(.hooks.PostToolUseFailure)' "$VIGIL_SETTINGS" > "$TEST_TEMP/s" && command mv "$TEST_TEMP/s" "$VIGIL_SETTINGS"
  run vigil_doctor
  [[ "$output" =~ partly\ +snapshots\ around\ each\ command\ +vigil\ snapshots\ on ]]
  # With --shell, the prefix too.
  run vigil_setup --shell
  [ "$status" -eq 0 ]
  [[ "$output" =~ on\ +commands\ followed ]]
  [[ "$output" =~ on\ +snapshots\ around\ each\ command ]]
  # A settings file that is not JSON is said to be, and left alone.
  echo 'not json' > "$VIGIL_SETTINGS"
  run vigil_doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"not a JSON object"* ]]
  run vigil_setup
  [ "$status" -ne 0 ]
  [ "$(cat "$VIGIL_SETTINGS")" = "not json" ]
}

_call_event() {
  # $1 the event, $2 the call's id, $3 where, $4 a subagent's id if any.
  printf '{"hook_event_name":"%s","session_id":"s-1","prompt_id":"p-1","cwd":"%s","tool_name":"Bash","tool_use_id":"%s"%s}' \
    "$1" "$3" "$2" "${4:+,\"agent_id\":\"$4\"}"
}

@test "a snapshot around a command is kept only where the files changed, and names the call and what was before" {
  _repository
  export COOKED_HOST_SESSION="proj.1"
  local here="$TEST_TEMP/repo" at_prompt
  _snapshot_event UserPromptSubmit p-1 "$here" | vigil_snapshot
  at_prompt=$(git rev-parse "$VIGIL_SNAPSHOT_REF")
  # A command that changes nothing leaves nothing, before or after.
  _call_event PreToolUse toolu_01 "$here" | vigil_snapshot
  _call_event PostToolUse toolu_01 "$here" | vigil_snapshot
  [ "$(git rev-parse "$VIGIL_SNAPSHOT_REF")" = "$at_prompt" ]
  # One that changes a file -- a sed, say -- leaves one after it: against the
  # one it names, what it changed.
  _call_event PreToolUse toolu_02 "$here" | vigil_snapshot
  echo three > tracked
  _call_event PostToolUse toolu_02 "$here" | vigil_snapshot
  local after; after=$(git rev-parse "$VIGIL_SNAPSHOT_REF")
  [ "$(git log -1 --format=%s "$after")" = "vigil PostToolUse s-1 p-1 proj.1 claude toolu_02 $at_prompt" ]
  [ "$(git diff --name-status "$at_prompt" "$after" | tr '\t\n' '  ')" = "M tracked " ]
  # What changed with no command running is kept before the next one, and is
  # not that command's; what the command changes, failing, is.
  echo mine > by-hand
  _call_event PreToolUse toolu_03 "$here" | vigil_snapshot
  local before; before=$(git rev-parse "$VIGIL_SNAPSHOT_REF")
  [ "$(git log -1 --format=%s "$before")" = "vigil PreToolUse s-1 p-1 proj.1 claude toolu_03 $after" ]
  echo four > tracked
  _call_event PostToolUseFailure toolu_03 "$here" | vigil_snapshot
  local failed; failed=$(git rev-parse "$VIGIL_SNAPSHOT_REF")
  [ "$(git log -1 --format=%s "$failed")" = "vigil PostToolUseFailure s-1 p-1 proj.1 claude toolu_03 $before" ]
  [ "$(git diff --name-only "$before" "$failed")" = "tracked" ]
  # A subagent's command is one too.
  echo five > tracked
  _call_event PostToolUse toolu_04 "$here" a1 | vigil_snapshot
  [ "$(git log -1 --format=%s "$VIGIL_SNAPSHOT_REF")" = "vigil PostToolUse s-1 p-1 proj.1 claude toolu_04 $failed" ]
  # Turned off, or with no call named, none is kept; and the first ever kept
  # of a repository has none before it to name.
  local kept; kept=$(git rev-parse "$VIGIL_SNAPSHOT_REF")
  echo six > tracked
  _call_event PostToolUse toolu_05 "$here" | VIGIL_SNAPSHOT_CALLS=0 vigil_snapshot
  printf '{"hook_event_name":"PostToolUse","session_id":"s-1","cwd":"%s"}' "$here" | vigil_snapshot
  [ "$(git rev-parse "$VIGIL_SNAPSHOT_REF")" = "$kept" ]
  run vigil_snapshots forget "$here"
  _call_event PreToolUse toolu_06 "$here" | vigil_snapshot
  [ "$(git log -1 --format=%s "$VIGIL_SNAPSHOT_REF")" = "vigil PreToolUse s-1 p-1 proj.1 claude toolu_06 -" ]
  # The repository is as it was.
  [ -z "$(git for-each-ref refs/heads | grep -v main)" ]
}

@test "asked for a snapshot to look at, with nothing changed, the last one is it" {
  _repository
  local first second third
  first=$(vigil_snapshot_take . View)
  second=$(vigil_snapshot_take . View)
  [ -n "$first" ] && [ "$second" = "$first" ]
  [ "$(git log -g --format=%H "$VIGIL_SNAPSHOT_REF" | wc -l | tr -d ' ')" = 1 ]
  echo changed > tracked
  third=$(vigil_snapshot_take . View)
  [ "$third" != "$first" ]
  [ "$(vigil_snapshot_take . View)" = "$third" ]
  [ "$(git log -g --format=%H "$VIGIL_SNAPSHOT_REF" | wc -l | tr -d ' ')" = 2 ]
}

@test "that nothing changed since the last snapshot is told without taking one" {
  _repository
  refute _vigil_snapshot_unchanged .git/vigil-index
  vigil_snapshot_take . View >/dev/null
  # With a file too big to keep lying there, as before.
  _vigil_snapshot_unchanged .git/vigil-index
  echo three > tracked
  refute _vigil_snapshot_unchanged .git/vigil-index
  vigil_snapshot_take . View >/dev/null
  echo more > added
  refute _vigil_snapshot_unchanged .git/vigil-index
  vigil_snapshot_take . View >/dev/null
  command rm -f sub/untracked
  refute _vigil_snapshot_unchanged .git/vigil-index
  vigil_snapshot_take . View >/dev/null
  # A link is kept whatever it points to; a small file grown big is a change.
  ln -s big link
  refute _vigil_snapshot_unchanged .git/vigil-index
  vigil_snapshot_take . View >/dev/null
  head -c 4096 /dev/zero > added
  refute _vigil_snapshot_unchanged .git/vigil-index
  vigil_snapshot_take . View >/dev/null
  _vigil_snapshot_unchanged .git/vigil-index
  # What the repository's own index is told changes no file: a big file
  # that git now tracks, and so is kept, is kept from the next one taken.
  git add added
  _vigil_snapshot_unchanged .git/vigil-index
  vigil_snapshot_take . View >/dev/null
  [ "$(git ls-tree -r --name-only "$VIGIL_SNAPSHOT_REF" | grep -c '^added$')" = 1 ]
  # More big files than are worth a look: not told, and a snapshot says it.
  local n before
  for n in 1 2 3 4 5 6 7 8 9; do head -c 4096 /dev/zero > "big$n"; done
  refute _vigil_snapshot_unchanged .git/vigil-index
  before=$(git rev-parse "$VIGIL_SNAPSHOT_REF")
  vigil_snapshot_take . PreToolUse s p h claude toolu_1
  [ "$(git rev-parse "$VIGIL_SNAPSHOT_REF")" = "$before" ]
}

@test "a snapshot is of what git tracks now, and what it neither tracks nor ignores now" {
  _repository
  local a b
  a=$(vigil_snapshot_take . View)
  # Committed since, though over the size: tracked, so kept.
  git add big && git -c user.name=T -c user.email=t@example.org commit -q -m big
  # Ignored since, grown too big since, and no longer tracked since.
  echo sub/untracked >> .gitignore
  echo small > grows; echo mine > kept
  b=$(vigil_snapshot_take . View)
  [ "$(git ls-tree -r --name-only "$b" | tr '\n' ' ')" = ".gitignore big grows kept tracked " ]
  head -c 4096 /dev/zero > grows
  git rm -q --cached tracked
  b=$(vigil_snapshot_take . View)
  # `tracked' is still a file nobody ignores: kept as one git does not track.
  [ "$(git ls-tree -r --name-only "$b" | tr '\n' ' ')" = ".gitignore big kept tracked " ]
  # A directory where a file was, and a file where a directory was.
  command rm -f kept && mkdir kept && echo inside > kept/file
  command rm -rf sub && echo flat > sub
  b=$(vigil_snapshot_take . View)
  [ "$(git ls-tree -r --name-only "$b" | tr '\n' ' ')" = ".gitignore big kept/file sub tracked " ]
  [ -n "$a" ]
}

@test "a snapshot never writes a split index, nor touches the repository's" {
  _repository
  git config core.splitIndex true
  git update-index --split-index
  local shared before
  shared=$(ls .git/sharedindex.* | sort)
  [ -n "$shared" ]
  before=$(shasum .git/index $shared)
  vigil_snapshot_take . View >/dev/null
  echo more > more; echo three > tracked
  vigil_snapshot_take . View >/dev/null
  [ "$(ls .git/sharedindex.* | sort)" = "$shared" ]
  [ "$(shasum .git/index $shared)" = "$before" ]
  git status --porcelain >/dev/null
}

@test "asked for a snapshot now, vigil says whether it could take one" {
  _repository
  run env -u VIGIL_TESTING "$BATS_TEST_DIRNAME/../bin/vigil" snapshot --now "$TEST_TEMP/repo"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9a-f]{40}$ ]]
  mkdir -p "$TEST_TEMP/nowhere"
  run env -u VIGIL_TESTING "$BATS_TEST_DIRNAME/../bin/vigil" snapshot --now "$TEST_TEMP/nowhere"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

# --- locks, options, and other people's settings -----------------------------------

@test "a lock left by one that died is taken over, and one that cannot be made is given up" {
  local lock="$TEST_TEMP/lock"
  _vigil_lock "$lock"
  [ "$(cat "$lock/pid")" = "$$" ]
  # Held by someone alive: not taken, and not waited for beyond what was asked.
  SECONDS=0
  refute _vigil_lock "$lock" 1
  [ "$SECONDS" -le 3 ]
  _vigil_unlock "$lock"
  [ ! -e "$lock" ]
  # Held by nobody alive: taken at once.
  mkdir "$lock" && echo 999999 > "$lock/pid"
  SECONDS=0
  _vigil_lock "$lock" 5
  [ "$SECONDS" -le 1 ]
  [ "$(cat "$lock/pid")" = "$$" ]
  _vigil_unlock "$lock"
  # Nowhere to make it: said so, not tried for ever.
  refute _vigil_lock "$TEST_TEMP/no/such/place/lock" 5
}

@test "an option that needs a value and has none is refused, not waited on" {
  run vigil_hooks install --settings
  [ "$status" -eq 1 ]
  [[ "$output" == *"--settings needs a value"* ]]
  run vigil_hooks install --agent
  [ "$status" -eq 1 ]
  # pi has no settings for coverage or snapshots to be put in.
  run vigil_snapshots on --agent pi --dry-run
  [ "$status" -eq 1 ]
  [ ! -e "$VIGIL_PI_EXTENSIONS/vigil.ts" ]
  run vigil_coverage on --agent pi
  [ "$status" -eq 1 ]
  [ ! -e "$VIGIL_PI_EXTENSIONS/vigil.ts" ]
}

@test "only vigil's own command is taken out of the settings, and the file stays what it was" {
  mkdir -p "$(dirname "$VIGIL_SETTINGS")" "$TEST_TEMP/dotfiles"
  # A hook of somebody's in the same entry as vigil's, one that only has
  # vigil's words in it, and a name that is not ASCII; the file itself a link.
  cat > "$TEST_TEMP/dotfiles/settings.json" <<'JSON'
{"name": "José",
 "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "/opt/bin/vigil hook", "async": true},
                              {"type": "command", "command": "my-linter"}]},
                    {"hooks": [{"type": "command", "command": "echo vigil hook ran"}]}]}}
JSON
  ln -s "$TEST_TEMP/dotfiles/settings.json" "$VIGIL_SETTINGS"
  run vigil_hooks uninstall
  [ "$status" -eq 0 ]
  [ -L "$VIGIL_SETTINGS" ]
  [ "$(jq -c '.hooks.Stop | map(.hooks | map(.command))' "$VIGIL_SETTINGS")" \
    = '[["my-linter"],["echo vigil hook ran"]]' ]
  grep -q 'José' "$TEST_TEMP/dotfiles/settings.json"
  [ ! -e "$TEST_TEMP/dotfiles/settings.json.vigil-tmp" ]
  # Put back, it is one entry of vigil's own.
  vigil_hooks install >/dev/null
  [ "$(jq -c '.hooks.Stop | map(.hooks | map(.command))' "$VIGIL_SETTINGS")" \
    = '[["my-linter"],["echo vigil hook ran"],["vigil hook"]]' ]
}
