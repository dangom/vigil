# vigil

vigil keeps a record, on your machine, of what a coding agent did and shows it in Emacs:
every command it ran, every file it read or changed, every prompt and reply. Each is one
key away from the line of the conversation where it happened.

There are two parts:

- `bin/vigil`, a hook for Claude Code. Claude Code reports each prompt, tool call,
  subagent and reply to its hooks, and `vigil hook` writes each report to a file as it
  was given. It does nothing else.
- `emacs/vigil.el` and the files beside it, which read those reports and show them next
  to the agent's terminal.

[pi](https://pi.dev) is watched the same way, through an extension instead of hooks; see
[pi](#pi) below for what works with it so far.

## Requirements

- cooked, the Emacs terminal, from the [dangom/cooked](https://github.com/dangom/cooked)
  fork, `main` branch. vigil uses parts of cooked that are not yet in
  [upstream cooked](https://github.com/vodik/cooked): hosted sessions (`cooked-host`),
  annotations on the cooked buffer (`cooked-annotate`), the pop-up frame
  (`cooked-popup`) and the runs that save a command's output as it prints
  (`cooked-run`). The tests expect the fork checked out next to this repository, at
  `../cooked`.
- Claude Code, whose hooks are what gets recorded, or pi 1.5 or later.
- bash and Python 3 for the hook. `jq` and `bats` are needed only for the tests, and
  Node.js 24 or later for the tests of pi's extension (they are skipped without it).
- git and perl for snapshots (see below); without perl none are taken.
- Optionally, [shfmt](https://github.com/mvdan/sh), [ruff](https://github.com/astral-sh/ruff)
  and [prettier](https://prettier.io), to lay out the commands an agent ran (see below). Without them, commands are shown as
  given.

vigil does not need to know what started the agent. A `claude` you typed into a hosted
shell is watched the same way as one started by a session manager. The two halves find
each other by the session's name: cooked tells the program its session's name in
`COOKED_HOST_SESSION`, and a buffer attached to that session has the same name in
`cooked-host-name`.

## Where your data goes

vigil keeps whatever the agent saw: file contents, command output, web pages and your
prompts, including any secrets the agent read.

- It is written under `~/.local/share/vigil` (`$VIGIL_DATA_DIR`), outside this or any
  repository, and only your user can read it.
- To compare two versions of a file it edited, Emacs writes one of them to a temporary
  file only you can read, runs `diff` on it and deletes it straight away. While Emacs
  runs, it keeps every version of each file the agent edited, one per edit.
- vigil never opens a network connection, so none of it leaves the machine. A test
  checks that the code names no program that talks to another machine.
- Reports are parsed as JSON and displayed. They are never evaluated or sourced.

| Where | What | Kept |
|---|---|---|
| `records/<session>/` | One JSON file per hook event, as Claude Code wrote it (or pi's extension). | The newest 2,000 per session. Cleared when a new conversation starts under the same session name, and after 14 days without a report. |
| `prompts.jsonl` | Every prompt given to an agent. | The newest 5,000. |
| `archive/` | Every event again, verbatim, per conversation. | Indefinitely. `VIGIL_ARCHIVE=0` turns it off. |

An event over its size limit (4 MB in the records, 1 MB in the archive) keeps its shape,
but its biggest values are replaced by `{"vigil_truncated": true, "bytes": N, "head": "…"}`.

## Install

```sh
ln -s "$PWD/bin/vigil" ~/.local/bin/vigil
vigil setup --dry-run   # show what would change
vigil setup             # the record hook, snapshots, and pi's extension if pi is here
vigil doctor            # what is in place, and the command for each thing that is not
```

Then, in Emacs, with cooked and this repository's `emacs/` on the `load-path`:

```elisp
(require 'vigil)
(vigil-setup)
```

Restart any agent that was already running: it keeps the hooks it started with.

`vigil setup` does what the commands below do one by one, and can be run again after
updating vigil; it changes nothing that is already in place. `vigil setup --shell` also
follows commands as they run, which changes how Claude Code starts every command (see
below). `vigil doctor` only reads. Run it when something is not showing up: it says
`off`, `partly` (set up by an older vigil) or `old` beside what needs doing.

### What runs, and when

Three things can run when an agent does something. Only the snapshot is waited for.

| What | When | Waited for | Takes | Turned on by |
|---|---|---|---|---|
| `vigil hook` writes the report | every prompt, call, subagent and reply | no | nothing the agent notices | `vigil install-hooks` |
| `vigil snapshot` keeps the files as they are | a prompt given, the agent stopping | yes | about 0.07 s | `vigil snapshots on` |
| the same, around a command | before and after each Bash command | yes | about 0.04 s each when nothing has changed, 0.08 s when something has | `vigil snapshots on` |
| `vigil-shell` saves a command's output as it prints | each Bash command | it is the command | a few milliseconds | `vigil install-shell` |

The snapshot before a command has to be waited for: taken while the command ran, it
could already hold what the command changed. The one after is waited for so that the
agent's next call does not change files while they are being read, which would put
that call's changes on this command.

Almost all of a snapshot's time is starting programs, not reading files: git is started
about a dozen times, and each start costs a few milliseconds. So around a command vigil
first asks git one question, whether any file differs from the last snapshot, and stops
there when none does, which is most of the time. On macOS, `/usr/bin/git` is a program
that finds git and then runs it, three times slower to start than git; vigil runs the
git it would find directly.

### One by one

```sh
vigil install-hooks --dry-run   # show what would change in ~/.claude/settings.json
vigil install-hooks             # merge vigil's hook in, keeping all others
vigil uninstall-hooks           # take it out again, keeping all others
```

`install-hooks` and `uninstall-hooks` first back up the settings file to
`settings.json.vigil-backup-<time>`, and a backup never overwrites an existing file. The
hook runs asynchronously on every event, so the agent never waits for it. Agents that are
already running keep the hooks they started with, so restart them to have them watched.

### pi

```sh
vigil install-hooks --agent pi --dry-run   # show what would be copied, or changed
vigil install-hooks --agent pi             # copy pi/vigil.ts to ~/.pi/agent/extensions/
vigil uninstall-hooks --agent pi           # remove it again
```

pi has no hooks in a settings file. It loads extensions, and `pi/vigil.ts` is one that
hands each of pi's events to the same `vigil hook`, one after another and without pi
waiting. Only a `vigil.ts` that is vigil's is ever replaced or removed. Run
`install-hooks --agent pi` again after updating vigil, and restart any pi that is running.
The extension needs `vigil` on pi's `PATH` (or its path in `VIGIL_BIN`). Outside a hosted
session it hands over no report; with snapshots on it still keeps those, since a snapshot
belongs to the repository.

A report from pi keeps pi's own tool inputs and results, under the names the hook already
files by, and is marked `"agent": "pi"`. The extension adds two things pi does not report:
how much context the model had read at each call, and the file an `edit` or `write` is
about to change, as it was before (files up to 1 MB).

What works with pi: the call frame (commands, diffs, files read), `vigil-context`, a
turn's list and its diff, the marks in your files, prompts, the archive and its export.
What does not yet:

- **The marks in the conversation, prompt navigation and focus** need the conversation as
  text that stays put. pi's default full-screen mode gives the terminal no such text, so
  start it with `pi --tui-mode regular` (or set `"tuiMode": "regular"` in
  `~/.pi/agent/settings.json`). Even then these are untested with pi.
- **Following commands while they run** (below) is for Claude Code only.
- pi has no subagents of its own, so there are none to show.
- Two `edit` calls to one file in the same reply are each given the file as it was before
  either ran, so the second one's lines may be credited wrongly.

### Following commands while they run (optional)

```sh
vigil install-shell --dry-run
vigil install-shell     # sets "env": {"CLAUDE_CODE_SHELL_PREFIX": ".../bin/vigil-shell"}
vigil check-shell       # ask the installed Claude Code to run one command through it
vigil uninstall-shell
```

After this, Claude Code runs every shell command through `bin/vigil-shell`. When the
command comes from the Bash tool in a hosted session, the wrapper hands it to cooked's
`cooked-host run`. That runs the command exactly as it would have run, and also saves its
output as it arrives under `~/.local/state/cooked/runs` (readable only by you; the newest
200 per session). Anything else Claude Code runs through the prefix, such as its hooks and
status line, runs as if the prefix weren't there. So does every command outside a hosted
session or on a machine without cooked. The wrapper adds a few milliseconds per command
and prints nothing of its own.

#### The sandbox

With Claude Code's sandbox on, the wrapper runs inside it. `install-shell` therefore also
adds cooked's runs directory to `sandbox.filesystem.allowWrite`, so a sandboxed command
can write to that one directory, where only command output is kept, and nowhere else new.
The entry has no effect while the sandbox is off, and `uninstall-shell` removes it.

#### If Claude Code changes

The wrapper recognizes the Bash tool's commands by their shape, which Claude Code does
not document. If a future version changes that shape, commands still run, but their
output is no longer saved as it arrives. There are two ways to notice:

- `vigil check-shell` asks the installed Claude Code to really run one command through
  the wrapper, and reports whether the wrapper recognized it. It starts `claude` once,
  on its smallest model, in a scratch directory. Run it after updating Claude Code.
- In Emacs, vigil compares the runs with the hooks' reports, which *are* documented. If
  several commands in a row (`vigil-unfollowed-limit`, 3) were reported but none of them
  was saved, it warns you once and says what to check.

### Emacs

vigil binds no global keys. `M-x vigil` is the one command to bind: everything else is a
key away from the buffer it opens.

## Features

### One place to begin: `M-x vigil`

`M-x vigil`, or `C-c C-s` in an agent's buffer, opens one buffer for that session, as
`magit-status` does for a repository. Elsewhere, or with `C-u`, it asks which session,
the one last heard of first. A session that is not open in this Emacs is shown as well,
from its reports.

The session, its repository and its branch are in the header line. The views are in the
tab line above it, each with its key, the one showing marked:

| Key | View | What it shows |
|---|---|---|
| `s` | Status | When it began, how many prompts and calls, how long its commands took, what is running, what it is working on, what it built; then the files changing now, its last prompts, and the commits made since it began. |
| `P` | Prompts | Each prompt on one line, the last first: when, how long, its turn as a timeline, and in a wide window how many calls, files and lines. The prompt at point is shown in full: its text, every call it led to (when, counted from the prompt; how long; what kind; what), and the reply. So a prompt is read with what came before and after it. |
| `a` | Answers | The replies alone, each under the prompt it answers. |
| `c` | Commands | Every command the session ran: under which prompt, when, how long it took, what it did (ran, or wrote: changed files), and whether it failed. Those that only looked are counted and left out; `L` lists them. `D` lists the longest first. |
| `l` | Changes | The files changing now, and what is changing in each: see below. |
| `b` | Build | The prompts and the repository's commits by when they happened, the last first. A prompt says how many files changed after it; a commit says its branches and tags, and which versions it added to `CHANGELOG.md` (`vigil-status-changelog`). |

In any of them:

- `RET` opens what is at point: a call in vigil's frame, a commit (in Magit where it is
  loaded), a prompt and what it led to, a file's diff, or a line of a diff in its file.
- `TAB` folds and unfolds, `S-TAB` all, where what a line led to is under it (`v`); a
  mark at the line's beginning says which way a line is. `M-n` and `M-p` go from prompt to prompt, or from file to file.
- `w` copies the prompt or the reply at point, whole and as it was written.
- `d` shows what changed after the prompt at point, or the commit at point.
- `o` visits the file at point, or goes to the line of the conversation where the call
  at point shows.
- `g` reads the session again.

#### A list, and what is at point beside it

The buffer is lists: a line a prompt, a command, a file, a commit. What the line at
point led to is shown in full in a second window, which follows as you move:

| At point | Beside it |
|---|---|
| a prompt | its timeline, the prompt in full, each call it led to, the reply, and the files that changed after it |
| a prompt, in Answers | the reply alone |
| a command, in Commands | the command, which prompt it was for, when in the turn, how long |
| a file | its diff |
| a commit | what it says, which versions it added to the changelog, the files it changed |

The window is to the right where there is room for two side by side (150 columns), and
below otherwise. `RET` goes to it; there, `RET` opens a call or a line of a diff, `w`
copies, and `q` leaves. `v` turns it off for the buffer: what a line led to is then
under the line, folded, and `TAB` opens it. `vigil-status-detail` set to nil makes that
the way every session's buffer begins.

#### A turn as a timeline

Beside each prompt is its turn drawn as a strip, as long as the turn was among the
session's turns (`vigil-status-strip-width`, 24 characters for the longest):

```
   #  When     Took  Timeline                  Prompt
   3  10:02  11m33s  █──────────████           Add a parser for the config file, an…
   5  10:21   3m34s  █████                     Run the tests again and fix what fai…
   8  10:40  18m38s  ────────███─█─█───██████  Now document it, and add an example …

  █ failed   █ command   ▓ edit or write   ░ read or look   ▚ subagent   ▒ other   ─ between calls
```

Each character is an equal share of the turn, drawn as the kind of call that took most
of it, or as `─` where calls took under a third of it: the agent was thinking, or
writing. A share in which a call failed is drawn as failed. Each kind has a character of
its own as well as a face (`vigil-ui-kind-command`, `-edit`, `-read`, `-subagent`,
`-other`, and `vigil-ui-bad`), since a theme may give two of them one colour. Beside
the list, the turn at point has the same strip as wide as its window, from 0 to how long
it took.

#### A command is one of three things

An agent does most of its work with shell commands: it reads with `cat`, `grep` and
`git log`, and it writes files with scripts and redirections as much as with its editing
tools. So a command is told to be one of three, wherever calls are counted, listed or
drawn:

| | When | Drawn as |
|---|---|---|
| a write | a snapshot kept after it says the files differed, or its words write a file | `▓`, as an edit is |
| a look | not a write, and its words only look | `░`, as a read is |
| a command | neither: it ran something | `█` |

The counts say so ("139 calls: 56 commands, 34 writes, 35 looks, 5 edits"), a prompt's
list of calls names each, and Commands says of each whether it ran or wrote, leaving the
looks out until `L` lists them. An edit is a call to an editing tool; a write is a
command that changed files.

Its words only look when every program it runs is one of
`vigil-status-looking-programs`, used so as only to look (`sed` without `-i`, `find`
without `-delete` or `-exec`, `git` with one of `vigil-status-looking-git`), and it
writes no file with a redirection.

What to know:

- It errs towards a command. A program not on the list runs something, so
  `python3 script.py` and `git stash list` are commands though they may only read.
- A write is known two ways, and either is enough. By the snapshot kept after the
  command, which sees whatever it did, script or not, to the repository's files that git
  does not ignore. And by its words: a redirection to a file, `sed -i`, or one of
  `vigil-status-writing-programs` (`cp`, `mv`, `rm`, `tee`), which also sees files
  outside the repository. What a script writes is not in its command's words, so
  without snapshots `python3 gen.py` is a command. In the session this was written in,
  of 43 writes the snapshots found 35 and the words 17.
- A command that ran the tests and wrote a file is a write.

In a timeline an edit takes no time worth a character, so it is drawn where it was made
if nothing else took that share of the turn. A subagent's own calls are not drawn, only
the call that launched it.

The buffer reads the session again by itself, a moment after its agent reports anything
(`vigil-status-refresh-delay`), while it is on screen. It stays where you left it: the
same line, the same things folded.

#### What is changing now

`l`, or `M-x vigil-live`, or `C-c C-w` in an agent's buffer: the files that differ from
when the last prompt was given, the one written last first, with how many lines went in
and out and how long ago. Under the list is each file's diff, the last written one
showing and the others folded.

- It is read again as the agent works, and while it follows (`F` turns that off and on)
  it goes to the line that is new: the first line of the last written file's diff that
  was not there the time before.
- `T` counts from the session's beginning in place of the last prompt.
- `RET` on a line of a diff visits its file at that line; on a file, in the list or in
  Status, it shows that file's diff.
- The first 12 files have their diff laid out (`vigil-status-live-files`).

This needs snapshots (`vigil snapshots on`, which `vigil setup` does). What is shown is
the repository as it is now against the snapshot kept at the prompt, so it is everything
that changed since, whoever changed it. Asking how things are now keeps no snapshot when
nothing has changed since the last one.

#### How it is laid out

Tables are as wide as what is in them and never wider than the window: one column, the
prompt or the command, is cut to the room there is. A prompt and a reply are each a block
with a rule down its left side, filled to 88 columns (`vigil-ui-text-width`) or to the
window where that is narrower, a list item hanging under its own words. Every list is
the last first: the prompt, reply, command or commit that is newest is at the top, and
is where a view opens. Change the window's width and the
buffer is laid out again (`vigil-ui-max-width` is the widest it goes, 140 columns).
Replies are written in Markdown: headings, bold, code and bullets are shown as such,
with the marks hidden.

Every face inherits a standard one (`bold`, `shadow`, `success`, `error`, `warning`,
`help-key-binding`, the tab line's), so a theme styles vigil without knowing of it. The
faces are `vigil-ui-heading`, `-dim`, `-strong`, `-key`, `-good`, `-bad`, `-busy`,
`-code`, `-tab` and `-tab-current`.

`?` (or `h`) shows a menu of the views and of the rest of vigil, and the same keys work
without it:

| Key | Goes to |
|---|---|
| `r` | [What the session built](#what-a-session-built-m-x-vigil-review) |
| `x` | [Its context](#m-x-vigil-context) |
| `t` | [A turn, call by call](#a-turn-call-by-call) |
| `G` | [Its turns as a graph](#m-x-vigil-graph) |
| `f` | [Focus](#focus) in its conversation |
| `y` | Paste an [earlier prompt](#prompts) at its input |
| `R` | [Running commands](#m-x-vigil-running) |
| `C` | [Where the repository is changing](#m-x-vigil-codebase) |
| `A` | [The archive](#the-archive) |
| `S` | Another session |

What to know:

- The views are read from the session's reports, which are kept for 14 days and start
  afresh when the agent is started anew under the same name.
- A call, the context, a turn's list and focus act on the agent's buffer: for a session
  that is not open in this Emacs they say so.
- Only the reply that ended each turn is reported, not what the agent said between
  calls: that is all Answers has.
- A call that fails is reported as failed, with when (0.3.1; run `vigil setup` again
  after updating, and restart the agents). One that failed before that reported no end:
  once its agent has gone on, it is listed as "no end", with no duration, and is not
  counted as running.
- The files and lines beside a prompt are what changed between the snapshot kept when
  it was given and the one kept at the next prompt. A message sent while the agent is
  at work is a prompt of its own, with its own snapshot: what changed after it is
  beside it, not beside the prompt that began the turn. It is by time, not by cause:
  work the agent was already doing for the earlier prompt, finished after the message
  arrived, is beside the message.
- Asking a new question from a reply, or forking the conversation there, is not built.

### Calls in the conversation

A wedge in the fringe marks each line where a command ran, a file was changed or a
subagent was launched. When the agent shows calls only as a summary ("Read 2 files"),
they are marked together on that line. Click a wedge, or press RET on the line, and a
small frame opens over the agent. It shows a command highlighted as shell with its
output, an edit as a diff, a file that was read with its contents (an image as the image),
or a subagent's task and result.

A subagent is said to be running, done, failed or interrupted: failed when the call that
launched it came back an error, interrupted when the agent was waiting for it and has
since replied or been prompted without the subagent saying it was done. While it runs,
the frame, the context list and the turn's list also say how many calls it has made and
what the last one is ("7 calls · Bash pytest -x").

In the frame, `]` and `[` step through the calls, `o` goes to the call's line, `v` visits
an edited file and `q` closes. The header line shows:

- what the call is and when it ran;
- the turn it was in (`turn 3/5` means after your third prompt of five);
- its position in that turn and among all the agent's calls (`call 4/12 (41/87)`);
- how much context the request that made it had read (`55k context`: its input, cached
  or not, from Claude Code's transcript; for a subagent's call, the subagent's own
  context);
- the directory it ran in.

The keys are listed in the frame's bottom line.

As each call is shown, the conversation behind the frame scrolls its line into the part
the frame leaves uncovered and briefly lights it up. For a subagent's call, that is the
line of the Agent call that launched it. `q` puts the conversation back where it was, or
at its end if you were following it. Set `vigil-follow-calls` to nil to turn this off.

### Commands laid out to be read

In the frame, shfmt parses each command and prints it again, putting each link of a long
`&&`, `||` or `|` chain on its own line. Programs embedded in the command are moved into
blocks of their own, highlighted in their language and marked `‹1›` where they were.
That covers the Python of `python3 -c "…"`, a heredoc fed to `python3 -`, `node -e`,
`osascript -e` (JavaScript with `-l JavaScript`), the Emacs Lisp of `emacs --eval` and
`emacsclient -e`, `bash -c`, and a heredoc written to a
file. Each block is laid out by its formatter (`ruff format` for Python, prettier for
JavaScript, Emacs's own `pp-emacs-lisp-code` for Emacs Lisp without comments or
character literals; see `vigil-command-formatters`), whether the command runs it
or writes it to a file. Lines still too long for the frame, such as a long string ruff
leaves whole, wrap under their own indentation.

`e` explains each program and each option it was given, from the manuals on this machine
(bash's `help` for a builtin, `man` for everything else). It stays on for later commands
until you press it again. `t` shows commands exactly as given, and files exactly as they
were written. Nothing in a command is ever run; the formatters only read it.

### The scripts a command names

A command such as `tools/heavy.sh /tmp/e2e/run.sh after 2>&1 | tail -20` says little:
what it does is in the two files. Inspecting it shows them under its output, each under
its name, highlighted, its first 60 lines (`vigil-command-script-lines`); the name is a
link to the whole file, and `s` turns the scripts off and on. A script is a file the
command's words name that exists, is text, and begins with `#!` or has a script's
extension (`vigil-command-script-extensions`). Arguments count as well as programs, so the
script handed to a wrapper is found, and a name after a `cd` is read from there. Words
the shell would have to expand (`$DIR/run.sh`) are not followed.

The files are shown as they are now. One changed since the command ran is shown as it
was changed, and the heading says so. Nothing is run: the command is parsed by shfmt and
the files are read.

### Commands as they run

With `vigil install-shell` (see above), a command that is still running opens as a
buffer that grows as it prints, colours included. So does a command left running in the
background, whose report says nothing about its output. Opening the buffer only reads
what was saved, though `k` there interrupts the command after asking. For a command that
has finished, `r` shows the same buffer, with all of the output in the order it came, and
`r` again goes back to the call's report.

That buffer works like `*compilation*`. Errors and warnings in it are found the way
`compile` finds them and are underlined where the program printed them without colour.
`M-g M-n` and `M-g M-p` go to them, as after a build of your own, and RET on one opens
its file at that line (in the frame, when the buffer is in the frame). The run you
looked at last is the one `next-error` walks. Compile's single-letter keys are left out,
so `g`, `k` and `q` keep their meaning here.

Nothing opens unasked. If you'd rather have a long command open by itself, the way
`compile` shows a build, set `vigil-show-runs-after` to a number of seconds: a command
still running that long after the agent started it opens in a side window at the bottom
of the agent's frame (`vigil-run-display-action`), without taking the cursor. The next
one replaces it. This happens only while the agent's buffer is on screen, and never for
a command left running in the background. The agent's terminal gets shorter to make
room, so the agent redraws.

### A turn, call by call

`C-c C-t` in an agent's buffer (or `T` on a call in the frame, or in the context buffer)
lists what the agent did in one turn, from one of your prompts to the next. A background
task reporting back stays inside its turn. The calls are listed in order, each with when
it began (counted from your prompt), how long it took, the context it was made in, and
what it did: "created src/x.py", "edited README.md", or the agent's own description of a
command followed by the command.

The list opens on the turn of the call marked nearest point, with that call selected.
Moving through the list scrolls the conversation behind it to each call and lights it up.
RET or a click opens the call in the same frame (`l` comes back to the list), `o` goes to
its line, and `]` and `[` go to the next and previous turn.

### `M-x vigil-running`

This lists every command the agents started that is still going: when it started, how
long it has run, how much CPU and memory it is using, why it was run, and what it is
doing now. CPU and memory are summed over the command and every process under it, as
`ps` reports them: CPU in percent of one core, so it can pass 100, and memory as resident
size, which counts pages shared between processes once for each. Both columns sort,
largest first. "Why" is the description the agent gave with the command, for an agent
open in this Emacs, and otherwise what the last script the command names says of itself in
the comment it begins with; moving to a line also says, in the echo area, the prompt the agent was
last given before it started the command. "Now" means the processes at the bottom of the
process tree under it, such as the `sleep 60` of a loop waiting for a file, or the Python
under `pixi run`. Each command fits on one line, laid out as above and highlighted
(`python3 -c ‹1›`, `cat > x.py << ‹1›`), and `c` shows it in full with its programs laid
out. The list refreshes itself while it is visible. The command on the cursor's line is shown
as it prints, in a window beside the list, and is the one `next-error` walks: move to
another line to see that one instead (`vigil-running-show-output` turns this off). RET
follows a command in the frame, the same as opening its call. `f` shows the files the command reads and writes, as far as they
have been seen: each time the list refreshes, one `lsof` lists what the command and every
process under it have open, and those are kept, written files apart from read ones, with
the program that had each open and whether it is open now. This is what the command
does, whatever it is written in, and not what its text says. A file opened and closed
between two refreshes is missed, nothing is seen while the list is not on show, and the
system's own files are left out (`vigil-running-files-ignore`). `q` closes the list and the
window beside it; in that window, `q` closes just the window. The list only watches and never signals a process.

### Edits in your files

A file an agent edited has a bar in the fringe beside each line one of its calls wrote.
The bar is bright for the turn under way (`vigil-edit-latest`) and dim for earlier turns
(`vigil-edit`). Hover over a line to see which call wrote it and when. Click the bar to
open that call, usually its diff, in the frame. `M-x vigil-blame` does the same for the
line at point, and with `C-u` goes to the call's line in the conversation instead. The
marks are on the left, drawn over diff-hl's: of the lines diff-hl marks as uncommitted,
those with vigil's bar were the agent's. Set `vigil-edits-fringe` to `right-fringe` to
keep them apart, or `vigil-mark-edits` to nil to turn the marks off.

Who wrote a line is worked out from the hooks' reports alone. Each edit's report has the
file as it was before the edit and the patch the edit made, and lines are followed from
one edit to the next. A command the agent ran that changed the file (a `sed -i`, a script) is
followed the same way where snapshots are kept around commands (see
[What a command changed](#what-a-command-changed)); without them it belongs to no call.
Anything else that changed the file in between (you, a formatter, a
`git checkout`) belongs to no call. The same goes for anything
in the buffer that differs from what the last edit left, saved or not. So a line the
agent wrote and you then rewrote is yours. The marks are redrawn when the agent edits the
file again, and when you save or revert the buffer. Only `diff` is run, on text already
in Emacs.

### A turn's changes as one diff

`d` in a turn's list, on a call in the frame, or in the context buffer (`M-x
vigil-turn-diff` anywhere) shows what that turn changed as one diff. Each file runs from
before the turn's first edit of it to after its last, so a change the agent made and
then took back doesn't appear. With `C-u`, it covers the whole conversation. The diff
opens in an ordinary window, in `diff-mode`, so `C-u C-c C-a` undoes one hunk in the
file and leaves the rest of the turn alone. Changes you made to a file between two of
the agent's edits in that turn are included.

### `M-x vigil-context`

This shows everything that has entered the agent's context, oldest first, one heading
each: prompts, every call with its full result, subagents with their calls folded under
them, session starts, and the reply that ended each turn. TAB unfolds a heading, S-TAB
folds all of them, and RET opens one in the frame. The top of the buffer lists what
Claude Code's hooks don't report, and so what is missing: the system prompt, CLAUDE.md and
memory files, compaction summaries, and the agent's own words between tool calls.

### Files

A file name in the conversation opens the file read-only in the same frame, highlighted
in its mode and at its line. Click it once it has scrolled up, or press `C-c RET` at
point. File names in the frame and in the context buffer work the same way. There, `v`
opens the file in a window, `l` goes back to the call it was opened from, `]` and `[` step
on from that call, and `q` closes. HTML files open in the browser.

### Focus

`C-c C-f` in an agent's buffer shows only your prompts and the agent's replies. Each
turn's work (reads, diffs, command output, subagents) is folded into one line that says
how many tool calls it took. `C-c C-f` again shows everything. Only the buffer's display
changes; the terminal is untouched. Isearch opens a folded turn to show a match inside
it. `M-x vigil-focus` toggles focus for the current agent from anywhere.

### Prompts

`C-c C-p` and `C-c C-n` in an agent's buffer move between your prompts in the
conversation. `M-x vigil-prompts` picks one of the prompts given to this agent (with
`C-u`, to any agent on this machine), newest first, and pastes it at the agent's input
without sending it.

### `M-x vigil-graph`

This draws an agent's last turn as a graph on a canvas ([canvacs](https://github.com/dangom/canvacs)):
the prompt, each call and the reply as cards joined in the order they happened, with a
subagent's calls branching off the call that launched it. A run of reads and searches
that all went well shares one card. Each turn is a row of its own, one under another,
and every row begins at the left with its prompt. A number as prefix argument shows that many turns, and
`C-u` alone shows every turn there is a record of. The canvas belongs to no file and is
made anew each time, so nothing of it is saved.

Each kind of step has one colour: prompts are cyan, replies purple, commands orange,
edits green, subagent launches yellow, and any call that failed is red. Reads, searches
and other tools are left plain. `vigil-graph-colours` changes them. `vigil-graph-data`
returns the same graph as data, without a canvas, and `vigil-graph-rows` a turn at a
time.

### Objectives and subagents, for a list of agents

`vigil-survey.el` answers three questions about a session by its name, with no agent
buffer attached, for whatever lists the agents that run:

- `vigil-survey-objective` gives what the agent is working on now, if it keeps a list of
  things to do (`TodoWrite`, or `TaskCreate` and `TaskUpdate`): the item in progress, and
  how many of the list are done. An agent that keeps no list has no objective.
- `vigil-survey-subagents` gives its subagents: what each was asked, whether it is
  running, done, failed or interrupted, how many calls it has made and what the last one
  is about.
- `vigil-survey-turns` gives its turns step by step, which is what the graph is drawn from.

Each report is read once and what it said is kept, so asking again reads only the
reports that are new. These functions never signal an error: a report that cannot be read
is passed over, and a session without reports has no objectives and no subagents.

Two things are worked out, since the reports do not say them:

- A subagent the agent waits for is tied to the call that launched it only when it is
  done. Until then it is given the oldest unanswered launch of its type, which is where
  its "what it was asked" comes from.
- A subagent that was waited for and never reported that it was done, while the agent has
  since been prompted or has replied, is shown as interrupted.

The shapes of `TaskCreate` and `TaskUpdate` (a `subject`, a `taskId`, a `status`) are
assumed: the tests use them, and no real report of either has been seen yet.

### Embark

With [Embark](https://github.com/oantolin/embark), a call is one target wherever it
shows, with one set of actions. Load it after vigil:

```elisp
(require 'vigil-embark)
```

`embark-act` then offers the same actions on a call's line in the conversation, on its
heading in the context, on its row of a turn, in the frame inspecting it, on a line it
wrote in a file, and on its row of the running commands. The keys each of those places
already has stay as they are. Nothing is loaded from Embark until Embark itself is, and
vigil works the same without it.

| Key | On a call |
| --- | --- |
| `RET` | inspect it |
| `o` | go to its line in the conversation |
| `t` | its turn, call by call |
| `d` | what its turn changed, as one diff |
| `v` | visit the file it edited |
| `w` | copy its command as given, or its input as JSON |
| `W` | copy its result |
| `e` | explain its command |
| `y` | paste its command at the agent's prompt, not submitted |

`w` takes the place of Embark's own copy, which would copy the call's name. The call
comes first among the targets on its line, so a file named there is reached by cycling.
A group of calls is acted on as its first call, and a subagent as the call that launched
it, once that is known.

A row of `vigil-archive` is a second kind of target, a session: `RET` opens it, `c`
shows its context (the live agent's, if it has one), `g` draws its graph and `e`
exports it.

For anything else that wants to offer the same actions: a call's target has the type
`vigil-call` and is the string `SESSION/CALL-ID`; a session's has the type
`vigil-session` and is the session's name. Only calls of sessions with a live agent
buffer can be acted on, so not those of an archived session opened from the archive.

### `M-x vigil-codebase`

When agents write the code, you do not read it as it is written. `vigil-codebase` is for
keeping a feel for it anyway. It lists the files of a repository that changed in the
last 30 days (`vigil-codebase-days`; `d` changes it), the most changed first:

| Column | What it says |
| --- | --- |
| Kind | `new`, `growing`, `churning` (changed three times or more, with at least 0.35 lines out for each one in), `new, reworked`, `changed` or `gone` |
| Changes, In, Out, Last | how many commits touched it, lines added and removed, and when it last changed; what is not committed counts as one more change |
| Prompts | how many prompts its changes go back to |
| Runs, Last run | how many commands exercised it, when the last one ran and whether it failed, and whether the file has changed since |

The header line sums the repository up: how much of what was added went into new files,
and how many lines came out for each one put in. That answers whether the work is
making new things or reworking the same ones.

RET on a file shows it alone: the functions that changed most often (as git names a
hunk's function, with patterns for Emacs Lisp and JavaScript that git lacks), its
commits, the prompts behind its changes, and the commands that exercised it with how
often each ran. RET on a prompt or a command shows it whole, and on a commit shows the
commit. `v` visits the file.

Where each part comes from:

- Kind, changes and lines come from git's log alone.
- Prompts and runs come from the archive (see below), read for the sessions that worked
  in the repository.
- A prompt is behind a file when an edit that followed it changed the file. An agent
  that changes files with a script and not its editing tools leaves no edit, so a
  command that redirects to the file, or is handed a program or a text naming it, counts
  too, and is listed as "a command that wrote it".
- A command exercised a file when it names the file (unless the program it gives the
  name to only reads files, like `cat`, `grep` or `git`), when what it printed names the
  file with a line number, as a traceback does, or when coverage says it ran code of it.
- A command that failed is known by having begun and never been answered. Its output is
  not in the archive, so a traceback in it is not seen.

It is fast because nothing is read twice. Git is asked for line counts only, and only
for commits it has not been asked about; what it said and what was read of each archived
session are kept under `~/.cache/vigil` (`vigil-codebase-cache-directory`,
`vigil-history-cache-directory`), which can be deleted at any time. The first look at a
large repository takes under a second, and later ones a tenth of that.

`vigil-codebase.el` and `vigil-history.el` need only Emacs and git: not the rest of
vigil, not cooked.

### In Magit

```elisp
(require 'vigil-magit)
(vigil-magit-mode 1)
```

With `vigil-magit-mode` on, Magit's buffers say more, from the same two sources:

- A commit's buffer has a section, "Prompts behind this commit", between the message
  and the diff. It lists the prompts whose edits wrote lines the commit adds (matched
  by the text of the lines, so it survives a rebase), those whose commands seem to have
  written its files, and, apart, those only asked while the commit was being made.
- Each file named in a diff, a commit or the status has its change in a few words
  beside it: `churning · 7 changes · 3 prompts · ran 2h ago ok, changed since`.
- `M-x vigil-magit-why` on a hunk, a file or a commit shows the prompts behind it.
- With Embark and `vigil-embark`, a hunk is the call that wrote it, where that call's
  session is live, so every action on a call applies to the hunk.

Nothing loads Magit, and with the mode off Magit's buffers are as they were.

### Which code a command ran

Naming a file is weak evidence that a command exercised it. For Python and Node
programs, vigil can know which functions ran:

```sh
vigil coverage on       # and `off`, `status`
```

This needs `vigil install-shell`, since it is `vigil-shell` that tells the programs. It
is off until turned on, because it changes the environment of the agent's commands:
`coverage/python` goes in front of `PYTHONPATH`, and `--require
coverage/node/vigil-coverage.cjs` in front of `NODE_OPTIONS`. Each program then notes
which functions of the repository it was started in were called, and writes them when it
exits to `~/.local/share/vigil/coverage/<session>/<when>/`. `vigil coverage on` also
adds that one directory to the sandbox's `allowWrite` in Claude Code's settings, as
`install-shell` does for the runs; `off` takes it out again.

- Python needs 3.12 or later (`sys.monitoring`); on an older one nothing is done. A
  function is watched only until its first call, so the program is not slowed. A
  `sitecustomize` of the project's own still runs.
- Node is asked, as the program exits, which functions V8 knows to have run. Nothing is
  counted while it runs, so a test runner's own coverage is left as it is; a function V8
  has already discarded can be missed.
- Only files of the repository are kept, not `site-packages` or `node_modules`.
- A command that runs no Python and no Node leaves nothing behind.
- Neither hook prints anything, and neither can make a program fail: whatever goes
  wrong, the program runs as if it were not there.
- Not seen: a program killed before it could exit, and one started with Python's `-S`
  or `-I`.

`vigil-codebase` then lists such a command as having *ran* the file, with the
functions.

### What a command changed

An agent changes most files with commands, not with its editing tools: a `sed -i`, a
script handed to `python3`. A command's report says what it printed and nothing of what
it changed. With snapshots on (below), one is also asked for before and after each
command, and the two are what the command changed:

- Inspecting the command shows, under its output, the files it changed with the lines
  put in and taken out, and their diff (its first 200 lines, `vigil-effects-diff-lines`).
- A turn's list names the files beside each command that changed any.
- The lines the command wrote are marked as its own in your files, `vigil-blame` on one
  opens the command, and a turn's diff has what its commands changed.

A command that fails is covered too. Most commands change nothing, so a snapshot around
one is kept only where the files differ from the last one kept: such a command costs the
time of looking (about 0.04 s before it and after it, which the agent waits for; see
[What runs, and when](#what-runs-and-when)) and leaves nothing behind. What changed while no command was running (you, a
formatter, another agent) is kept before the next command and is not that command's.

What this cannot tell:

- Two commands run at once, or a command and anything else at work in the repository
  while it ran: what changed in that time goes to the command that ended last.
- A command left running in the background is reported done before it has changed
  anything. What it changes later is nobody's.
- Files outside the repository the command ran in, files git ignores, and files too big
  for a snapshot are not seen. A file that is not text, or is over 1 MB
  (`vigil-effects-max-file-size`), is named but its lines are not followed.
- Only agents open in this Emacs are read, a little at a time, shortly after each
  report.

`VIGIL_SNAPSHOT_CALLS=0` keeps the snapshots at prompts and stops only. If snapshots
were already on, run `vigil snapshots on` again to add the hooks around commands, and
restart the agents. pi's extension asks for the same around its `bash` tool.

### What changed after a prompt

Git remembers what was committed, not what the files were when a prompt was given. With
snapshots on, vigil keeps that, in the repository's own `.git`:

```sh
vigil snapshots on      # and `off`, `status`; `forget` in a repository removes its snapshots
```

This puts a second hook, `vigil snapshot`, on a prompt being given, on the agent
stopping, and before and after each Bash command, failed or not. Unlike `vigil hook` it
is waited for, so that the files are kept as they were before the agent changes them;
it takes under a tenth of a second and prints nothing.

A snapshot is a commit that nothing else points to: the files git tracks as they are in
the working tree, and those it neither tracks nor ignores, up to 1 MB each
(`VIGIL_SNAPSHOT_MAX`). This is worked out again for each snapshot, so a file that has
since been ignored is no longer kept. Unchanged files cost nothing, since git already has
them.

- Your index, `HEAD`, branches, stash and files are not touched. A snapshot is made with
  an index of vigil's own, `.git/vigil-index`, which is never a split index, so that it
  shares no file with yours.
- A snapshot is whole or not there: the commit is written, then one ref is moved to it.
- The ref is `refs/worktree/vigil/snapshots`, one per working tree, never pushed or
  fetched. Older snapshots are held by its reflog, as stashes are, and git's own
  collection drops them after a month (`gc.reflogExpireUnreachable`).
- `git config vigil.snapshots false` in a repository turns them off for it.
- Whatever goes wrong, the hook says nothing and the prompt goes ahead.

In Emacs (`vigil-snapshot.el`):

- `d` on a prompt, wherever one is listed (`vigil-codebase`'s file view, `*vigil why*`,
  the prompts behind a commit in Magit), shows what changed after it.
- `M-x vigil-snapshot-latest` shows what changed after the last prompt given in this
  repository, and `M-x vigil-snapshot-changes-after` lets you choose the prompt.

The diff runs from the snapshot kept when the prompt was given to the last one kept when
its agent stopped. An agent that was interrupted never says it stopped: the diff then
runs to its next prompt, or to now, and says which. It is Magit's diff where Magit is
loaded, and git's in a plain buffer otherwise.

A snapshot is of the repository, not of an agent, so the diff is everything that changed
in that time. Beside each file vigil says what the archive knows: edits of this prompt,
a command of this prompt that wrote it, edits by another agent meanwhile, or nothing
known. Other agents at work in the repository in that time are named in the header.

A prompt given before snapshots were on has none. For it, `d` shows the lines the
agent's edits added, from the archive, and says that this is less than a diff.

Each snapshot says which agent it was for, `claude` or `pi`, and the diff's header names
it. pi has no settings to put a hook in: its extension (`vigil install-hooks --agent pi`)
takes the snapshots itself while they are on, and waits for the one at a prompt before
the agent begins. It also gives each of pi's prompts an id, which pi has none of, so
that its edits and commands go back to their prompt. Codex is not watched by vigil yet.

Only the repository the agent was started in is kept.

### What a session built: `M-x vigil-review`

Coming back to a session, the question is what it built, against what was there when it
began. `M-x vigil-review` in the agent's buffer answers it from the same snapshots, in
two buffers. Elsewhere in a repository it takes the session last at work there, and
`C-u M-x vigil-review` lets you choose.

The overview is the session in short:

```
From     10:02
To       11:39, which is now
Prompts  3
Showing  its end
Changed  2 new   +1374 −0

Prompts
  #  When   Prompt                                              Files  Lines
  1  10:02  What does the parser do with a missing file?
  2  10:04  Show me where the config is read
  3  10:30  Add a way to review what a session built, with tests      2  +1374

Files
  emacs/
    + vigil-review.el        +1088
  tests/
    + vigil-review-tests.el  +286
```

- `RET` on a file lays the files out to be read, at that one; `r` does so from the top.
- `.` and `,` step through the session a snapshot at a time, and `SPC` plays it
  (`vigil-review-play-seconds`). The tree is then the files as they were at that moment,
  with what had just changed marked `●`, and the prompt it belongs to marked `▸`. `RET`
  on a prompt goes to what that prompt left; `e` goes back to the end.
- `d` shows a diff: of the file at point, of what changed after the prompt at point, or
  of everything.
- `s` reviews from another beginning, `o` visits the file, `g` reads again.

The reading buffer is the files one after another, as the session left them: the new
ones first, then those that changed, then the names of those gone. Each is in its own
mode's colours. The lines the session put in are highlighted, and where it only took
lines out a line says how many.

What it did not touch is folded. In a changed file, each definition with no change in it
is folded to its first line, which says how many lines are under it; in a new file every
definition is, so that you first see what the file is made of. A file with no definitions
(notes, JSON) keeps three lines around each change and folds the rest
(`vigil-review-context`). Definitions are the major mode's own, so this works wherever
`beginning-of-defun` does.

- `TAB` folds and unfolds what the line begins: a definition, or under its name a whole
  file. `S-TAB` unfolds every definition, or folds them all. Searching opens what it
  finds.
- `n` and `p` go by file, `]` and `[` by change.
- `F` lays the buffer over as many windows side by side as fit, each 90 columns or more
  (`vigil-review-follow-width`), scrolling as one (`follow-mode`); `F` again puts the
  windows back.
- `RET` visits the file itself at that line, and `d` shows its diff.

What to know:

- A session is a hosted session by its name, from its latest beginning: an agent started
  again under the same name, or after `/clear`, begins anew. `s` chooses an earlier one,
  and the review then runs from there through every beginning after it.
- It ends where the agent last stopped. If it has not stopped, it ends now.
- Snapshots are of the repository: what another agent or you changed in that time is
  shown too.
- Between two snapshots is as fine as the steps get: one is kept at each prompt, at each
  stop, and around each command that changed files. An agent's edits with its editing
  tools show at the next of those.
- A file that is not text, or is over 400 kB (`vigil-review-max-file-size`), is named but
  not laid out.

### Where the code is

`vigil.el` is the half that needs no terminal: the records, the views of a call, the
context and the prompts. `vigil-pi.el` puts a report of pi's into the words the rest
reads, as it is read. `vigil-transcript.el` is the half that reads the agent's cooked
buffer: the marks, prompt navigation and focus. `vigil-command.el` lays commands out and
explains them, `vigil-running.el` lists what is running, `vigil-turn.el` lists a
turn's calls, `vigil-edits.el` marks the lines the agent wrote and shows a turn's diff,
`vigil-effects.el` reads what each command changed from the snapshots kept around it,
and `vigil-compile.el` makes run buffers work like compilations. `vigil-setup` loads
`vigil-transcript.el`, `vigil-turn.el`, `vigil-edits.el`, `vigil-effects.el` and
`vigil-compile.el`;
`vigil-running` loads its file when first called. `vigil-survey.el` reads a session's
reports by its name and needs neither `vigil.el` nor cooked; `vigil-graph.el` draws from
it, and needs canvacs only when a graph is asked for. `vigil-embark.el` gives calls and
sessions to Embark, and needs it only once it is loaded. `vigil-history.el` reads the
archive for one repository and `vigil-codebase.el` lists the repository's changes; they
need neither `vigil.el` nor cooked. `vigil-magit.el` shows what they know in Magit, and
needs it only once it is loaded. `vigil-snapshot.el` shows what changed after a prompt,
from the snapshots `bin/vigil` keeps, and `vigil-review.el` what a whole session built,
from the same. `vigil-status.el` is `M-x vigil`: one buffer for a session, its views,
and the menu to everything else; it reads through `vigil-survey.el` and needs `vigil.el`
only for what acts on an agent's buffer. `vigil-ui.el` is how its buffers and the
review's are laid out: sheets, tables, wrapped text and tabs. Under all of them, `vigil-base.el` is what every
reader of vigil's files shares (JSON, when a report happened, where things are kept), and
`vigil-git.el` is how the last five ask git; both need only Emacs. `coverage/` holds the few lines Python and Node load
when coverage is on.

## The archive

The hook also keeps every event verbatim and indefinitely, so you can study sessions
later and turn prompts into evals.

```
archive/YYYY/MM/<session_id>.jsonl   one line per event, in the order they came:
    {"t": <epoch seconds>, "host": <session name, or null>, "hosted": <bool>,
     "event": <the hook's JSON, verbatim>}
archive/index.jsonl                  one line per conversation, at its first event:
    {"session_id", "started", "host", "hosted", "file", "cwd",
     "git_branch", "git_commit", "model", "first_event"}
```

A conversation's file stays in the month it began. Lines are appended under a short lock,
so concurrent hooks never interleave. The git branch and commit are read from the
repository as it is on disk, and nothing is fetched.

An agent outside a hosted session (a `claude` in any other terminal) also runs the hook,
but it is archived only with `VIGIL_ARCHIVE_ALL=1`, flagged `"hosted": false`. This is
off by default because it carries a risk: Claude Code deletes its own transcripts after
a while (`cleanupPeriodDays`), but the archive keeps them indefinitely.

In Emacs (`(require 'vigil-archive)`):

- `M-x vigil-archive` lists the conversations (date, project, session, branch, prompts,
  tool calls). RET opens one read-only, in the same view as `vigil-context`, and `e`
  exports it.
- `M-x vigil-archive-export` writes an eval dataset from every conversation, with one
  JSON line per prompt you gave. Prompts the agent gives itself, such as a background
  task reporting back, stay inside the turn they arrived in.

```
{"schema": "vigil.prompt.v1",
 "session_id", "host", "hosted", "cwd", "git_branch", "git_commit", "model",
 "turn": 1,                       # its place in the conversation
 "prompt": "…", "prompt_time": <epoch>,
 "reply": "…" | null,             # the Stop hook's last_assistant_message
 "reply_time": <epoch> | null,
 "seconds": <reply_time (or last event) - prompt_time>,
 "tool_calls": [{"tool", "summary", "agent_id" (subagent, or null),
                 "status": "done" | "interrupted" | "unfinished", "duration_s"}],
 "subagents": [{"agent_id", "agent_type", "result"}],
 "label": {"outcome": null, "score": null, "notes": null}}   # for you to fill in
```

## Settings

`bin/vigil` reads these environment variables:

| Variable | Default | |
|---|---|---|
| `VIGIL_DATA_DIR` | `~/.local/share/vigil` | Where everything is kept. |
| `VIGIL_SESSION` | `$COOKED_HOST_SESSION` | The session to file records under. |
| `VIGIL_RECORDS_MAX` | 2000 | Records kept per session. |
| `VIGIL_KEEP_DAYS` | 14 | Days without a report before a session's records are deleted. |
| `VIGIL_PROMPT_HISTORY_MAX` | 5000 | Prompts kept. |
| `VIGIL_ARCHIVE` | 1 | 0 turns the archive off. |
| `VIGIL_ARCHIVE_ALL` | 0 | 1 also archives agents outside hosted sessions. |
| `VIGIL_SETTINGS` | `~/.claude/settings.json` | The file `install-hooks` edits. |
| `VIGIL_RECORDS_DIR` | `$VIGIL_DATA_DIR/records` | Where each session's records are kept. |
| `VIGIL_RECORD_MAX` | 4194304 | Bytes of one record; over it, its biggest parts are cut. |
| `VIGIL_PROMPT_HISTORY` | `$VIGIL_DATA_DIR/prompts.jsonl` | The prompt history. |
| `VIGIL_ARCHIVE_DIR` | `$VIGIL_DATA_DIR/archive` | The archive. |
| `VIGIL_ARCHIVE_RECORD_MAX` | 1048576 | Bytes of one archived event, cut the same way. |
| `VIGIL_COVERAGE` | unset | 1 turns coverage on for one command, 0 off, whatever `vigil coverage` says. |
| `VIGIL_COVERAGE_DIR` | `$VIGIL_DATA_DIR/coverage` | Where coverage is written. |
| `VIGIL_SNAPSHOTS` | 1 | 0 keeps no snapshot, whatever `vigil snapshots` says. |
| `VIGIL_SNAPSHOT_MAX` | 1048576 | Bytes of the biggest untracked file a snapshot keeps. |
| `VIGIL_SNAPSHOT_CALLS` | 1 | 0 keeps no snapshot around commands, only at prompts and stops. |
| `VIGIL_SNAPSHOT_REF` | `refs/worktree/vigil/snapshots` | The ref snapshots are kept under. |
| `VIGIL_PI_EXTENSIONS` | `~/.pi/agent/extensions` | Where pi's extension is installed. |
| `VIGIL_BIN` | `vigil` | The vigil that pi's extension runs. |

If you move these places, set `vigil-directory`, `vigil-prompt-history` and
`vigil-archive-directory` in Emacs to match.

## Tests

```sh
bats tests
emacs -Q --batch -L ../cooked/lisp -L emacs -l tests/vigil-tests.el \
      -f ert-run-tests-batch-and-exit
emacs -Q --batch -L ../cooked/lisp -L emacs -l tests/vigil-archive-tests.el \
      -f ert-run-tests-batch-and-exit
emacs -Q --batch -L ../cooked/lisp -L emacs -l tests/vigil-command-tests.el \
      -f ert-run-tests-batch-and-exit
emacs -Q --batch -L ../cooked/lisp -L emacs -l tests/vigil-running-tests.el \
      -f ert-run-tests-batch-and-exit
emacs -Q --batch -L ../cooked/lisp -L emacs -l tests/vigil-pi-tests.el \
      -f ert-run-tests-batch-and-exit
emacs -Q --batch -L ../cooked/lisp -L emacs -l tests/vigil-embark-tests.el \
      -f ert-run-tests-batch-and-exit
emacs -Q --batch -L ../cooked/lisp -L emacs -l tests/vigil-effects-tests.el \
      -f ert-run-tests-batch-and-exit
emacs -Q --batch -L emacs -l tests/vigil-codebase-tests.el \
      -f ert-run-tests-batch-and-exit
emacs -Q --batch -L emacs -l tests/vigil-magit-tests.el \
      -f ert-run-tests-batch-and-exit
emacs -Q --batch -L emacs -l tests/vigil-snapshot-tests.el \
      -f ert-run-tests-batch-and-exit
emacs -Q --batch -L emacs -l tests/vigil-review-tests.el \
      -f ert-run-tests-batch-and-exit
emacs -Q --batch -L emacs -l tests/vigil-status-tests.el \
      -f ert-run-tests-batch-and-exit
```

Each test writes made-up events to its own temporary directory.
