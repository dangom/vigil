# Changelog

All notable changes to vigil are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
vigil adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html). While it is
0.x, a new command, view or hook is a minor version, and a fix or a change to something
already there is a patch.

The version is in three places, kept the same: here, `VIGIL_VERSION` in `bin/vigil`
(`vigil version`), and `Version:` in `emacs/vigil.el`.

## [Unreleased]

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

[Unreleased]: https://github.com/dangom/vigil/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/dangom/vigil/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/dangom/vigil/releases/tag/v0.1.0
