# Changelog

All notable changes to vigil are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
vigil adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html). While it is
0.x, a new command, view or hook is a minor version, and a fix or a change to something
already there is a patch.

The version is in three places, kept the same: here, `VIGIL_VERSION` in `bin/vigil`
(`vigil version`), and `Version:` in `emacs/vigil.el`.

## [Unreleased]

## [0.8.0] - 2026-11-25

Nothing here changes what is shown. Load the files again, or restart Emacs: what was
one file is four.

### Changed

- `vigil-status.el` is four files, by what each is for: what is read of a session and
  every option (`vigil-status-session.el`), how it is drawn (`vigil-status-views.el`),
  the window beside (`vigil-status-detail.el`), and the buffer, its commands and keys
  (`vigil-status.el`).
- What a command is for is told in one place, `vigil-purpose.el`: that it only looked,
  or wrote by its words, is one of its tags, and the three kinds a command is counted
  and drawn as come from them. Every command has at least one.
- Folding is `vigil-ui.el`'s, for the review and the session's buffer alike.
- Every option is under one group, `vigil`, and all of `M-x vigil`'s are in one table
  in the README.
- Renamed, the old names still working: `vigil-status-strip-width` to
  `vigil-status-timeline-width`; `vigil-status-looking-programs`, `-looking-git`,
  `-writing-programs`, `-looks-p` and `-writes-p` to `vigil-purpose-`'s; and the
  commands `vigil-review-toggle` and `-toggle-all` to `vigil-ui-fold-toggle` and
  `-toggle-all`.

### Removed

- What nothing used, and what was written twice: two ways of saying what changed, two
  of showing a commit, three of going to a file's line, four commands that were one.

## [0.7.0] - 2026-11-25

### Added

- What a command was for: writing code, tests or documentation, by the files that
  differed after it; testing, checking, version control and setting up, by the programs
  it runs. Commands says it of each command and counts them, a prompt's turn is summed
  up by it, and a timeline draws a run of tests or a check apart. `vigil-purpose-rules`.
- Beside a command: why it was said to be each, the programs it runs and where they
  are, and of each Python program inside it what it imports, writes, reads and runs and
  how many assertions it makes, read off its syntax tree without running it.
- `vigil-purpose.el`, which says these of a command as text.

### Changed

- Commands says what a command was for where it said whether it ran or wrote.

## [0.6.0] - 2026-11-25

### Added

- A command shown whole in `M-x vigil` is laid out to be read, as in a call's frame:
  printed again by `shfmt` with long chains broken, highlighted as shell, and the
  programs inside it taken out to blocks of their own, formatted and highlighted in
  their language. `vigil-status-tidy` turns it off.
- What `shellcheck` says of a command is under it: warnings and errors, with where and
  their codes. `vigil-status-shellcheck` and `vigil-status-shellcheck-level`.
- In a list, a command its agent did not describe is the command itself on one line,
  highlighted.

## [0.5.3] - 2026-11-25

### Changed

- A command is a write by its words as well: a redirection to a file, `sed -i`, or a
  program that writes, moves or removes files. That finds writes outside the
  repository, and writes where no snapshot is kept.

### Fixed

- A command that sends one stream to another (`2>&1`) was never a look.

## [0.5.2] - 2026-11-25

### Changed

- A command after which the files differed is a write, counted apart and drawn in a
  timeline as an edit is: an agent writes files with commands as much as with its
  editing tools, and its timelines were all commands.
- An edit, which takes no time, is drawn in a timeline where it was made.
- Every list is the last first: Prompts, Answers, Commands and Build, as Status was.

## [0.5.1] - 2026-11-25

### Changed

- A command that only looked (`cat`, `grep`, `sed -n`, `git log`) is a look, not a
  command: by its words, and by no snapshot saying it changed files. Looks are counted
  apart, drawn as reads in a timeline, and left out of Commands, where `L` lists them.
  Commands says of each command whether it ran or wrote.
- Beside a command in Commands is now the command itself, whole.
- No line is left between one changed file and the next where their diffs are folded,
  and a file's mark is beside its name.

## [0.5.0] - 2026-11-25

### Added

- `M-x vigil` is lists, with what is at point shown in full in a window beside: a
  prompt's calls and reply, a reply alone, a command, a file's diff, a commit. It
  follows point. `v` puts what a line led to back under the line, and
  `vigil-status-detail` chooses how a buffer begins.
- A timeline beside each prompt: its turn as a strip, as long as the turn was, each
  character the kind of call that took most of that share of it. The turn at point has
  the same as wide as its window.
- `q` in a session's buffer closes the window beside it as well.

### Fixed

- A buffer shown in a window that is not the selected one was laid out in the wrong
  order: asking the window its width moved point to where the window's was.

## [0.4.1] - 2026-11-25

### Fixed

- The files and lines beside a prompt were those of its whole turn, all beside the
  turn's first prompt: a message sent while the agent worked is kept under the same id,
  and was taken for the same prompt. Each prompt now has what changed between its own
  snapshot and the next prompt's, and `d` on it shows that.
- Loading `vigil-status.el` or `vigil-review.el` again gives buffers already open the
  keys that are new: `l` was undefined after updating without restarting Emacs.

### Changed

- A prompt and a reply are each a block with a rule down its left side, filled to
  `vigil-ui-text-width` (88 columns) however wide the window.
- Status lists its last prompts and the commits the last first.

## [0.4.0] - 2026-11-25

### Added

- A Changes view in `M-x vigil` (`l`), and `M-x vigil-live`: the files changing now,
  the last written first, and the diff of each. It follows the last change as it is
  made (`F`), counts from the last prompt or from the session's beginning (`T`), and
  `RET` on a line of a diff visits its file there.
- `M-x vigil` reads the session again by itself as its agent reports, leaving the
  buffer where it was: the same line, the same things folded.
- `C-c C-s` in an agent's buffer opens `M-x vigil`, and `C-c C-w` what is changing now.
- Status lists the files changing now, and the repository's branch is in the header.
- `vigil-ui.el`: how vigil's buffers are laid out, and the faces they use, each
  inheriting a standard one.

### Changed

- `M-x vigil` and `M-x vigil-review` are laid out anew. The views are tabs in the tab
  line and the session is in the header line. What was a run of sentences is a sheet
  of labels; what was a list is a table, its columns aligned, fitted to the window and
  laid out again when the window's width changes. Prompts and replies wrap at words
  and hang under where they begin, and are copied as they were written. Replies show
  Markdown's headings, bold, code and bullets. A mark at the beginning of a line says
  whether it is folded.
- `vigil snapshot --now` keeps no new snapshot when nothing has changed since the last:
  it gives that one.

## [0.3.1] - 2026-11-25

Run `vigil setup` again after updating, and restart the agents: the hook has one more
event to listen for. `vigil doctor` says "partly" until then.

### Fixed

- A call that failed is said to have failed, and when. Claude Code reports one as an
  event of its own (`PostToolUseFailure`), which vigil did not listen for: a command
  that failed was shown as still running, in the session's views, the graph, the turn's
  list and the archive.

## [0.3.0] - 2026-11-25

### Added

- `M-x vigil`: one buffer for a session, and a key to each way of looking at it.
  - Status: the session in short, what it built, its last prompts, and the commits
    since it began.
  - Prompts: each prompt with what it led to, call by call, and its reply.
  - Answers: the replies alone, to read and to copy (`w`).
  - Commands: every command the session ran, when, and for how long; `D` lists the
    longest first.
  - Build: the prompts and the repository's commits in order, each commit with the
    versions it added to the changelog.
  - `?` shows a menu of these and of the rest of vigil: review, context, turns, graph,
    focus, running commands, the repository's changes, the archive.
- `vigil-graph-rows`: a session's turns as graphs, one a turn.

### Changed

- `vigil-graph` draws each turn as a row of its own, one under another, every row
  beginning at the left with its prompt. A reply is no longer joined to the next
  prompt.

## [0.2.0] - 2026-11-25

### Added

- `M-x vigil-review`: what a session built, against what was there when it began, from
  the snapshots vigil keeps.
  - An overview of the session: its prompts, each with how many files changed after it,
    and a tree of the files new, changed or gone.
  - The tree steps through the session a snapshot at a time (`.` and `,`), or plays
    (`SPC`).
  - A reading buffer of the files one after another: the lines the session put in
    highlighted, the definitions it did not touch folded, and `F` to lay it over
    several windows with `follow-mode`.
- `vigil version`, and the version at the top of `vigil doctor`.
- This changelog.

## [0.1.0] - 2026-11-24

Everything before versions were kept, from 2026-11-15 on.

### Added

- `bin/vigil`, a hook that keeps what Claude Code reports, and `vigil.el`, which shows
  it in Emacs beside the agent.
- The agent's edits marked in your files, and its commands shown as compilations.
- Commands laid out to be read: Python, JavaScript, Emacs Lisp and osascript's programs
  taken out of them.
- pi watched as well, through an extension.
- `vigil-survey`: a session's objectives and subagents by its name. `vigil-graph`: its
  turns as a graph.
- A subagent that failed or was interrupted is said to be, and a running one says how
  far it has got.
- A call as one Embark target, wherever it shows.
- `vigil-running`: what a running command uses, reads and writes. A command inspected
  is shown with the scripts it names.
- `vigil-snapshot`: what changed after a prompt. `vigil-codebase`: where a repository is
  changing. `vigil-magit`: what is behind a change, in Magit.
- What each command changed, from a snapshot kept before and after it.
- `vigil setup`, which puts everything in place with one command, and `vigil doctor`,
  which says what is in place.

[Unreleased]: https://github.com/dangom/vigil/compare/v0.8.0...HEAD
[0.8.0]: https://github.com/dangom/vigil/compare/v0.7.0...v0.8.0
[0.7.0]: https://github.com/dangom/vigil/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/dangom/vigil/compare/v0.5.3...v0.6.0
[0.5.3]: https://github.com/dangom/vigil/compare/v0.5.2...v0.5.3
[0.5.2]: https://github.com/dangom/vigil/compare/v0.5.1...v0.5.2
[0.5.1]: https://github.com/dangom/vigil/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/dangom/vigil/compare/v0.4.1...v0.5.0
[0.4.1]: https://github.com/dangom/vigil/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/dangom/vigil/compare/v0.3.1...v0.4.0
[0.3.1]: https://github.com/dangom/vigil/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/dangom/vigil/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/dangom/vigil/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/dangom/vigil/releases/tag/v0.1.0
