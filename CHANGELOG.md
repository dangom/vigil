# Changelog

What changed in vigil, newest first. The version is in three places, kept the same:
here, `VIGIL_VERSION` in `bin/vigil` (`vigil version`), and `Version:` in
`emacs/vigil.el`.

While vigil is 0.x: a new command, view or hook is a minor version (0.2.0 to 0.3.0); a
fix, or a change to something already there, is a patch (0.2.0 to 0.2.1). What you have
to do after updating, if anything, is said under the version.

## 0.2.0 (2026-11-25)

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

## 0.1.0 (2026-11-15 to 2026-11-24)

Everything before versions were kept, by the day it was committed.

- 11-24: `vigil setup` puts everything in place with one command; `vigil doctor` says
  what is in place.
- 11-24: what each command changed, from a snapshot kept before and after it.
- 11-23: what changed after a prompt (`vigil-snapshot`), where a repository is changing
  (`vigil-codebase`), and what is behind a change in Magit (`vigil-magit`).
- 11-21: `vigil-running` says what a running command uses, reads and writes; a command
  inspected is shown with the scripts it names.
- 11-21: a call is one Embark target, wherever it shows.
- 11-21: a subagent that failed or was interrupted is said to be, and a running one
  says how far it has got.
- 11-20: a session's objectives and subagents by its name (`vigil-survey`), and its
  turns as a graph (`vigil-graph`).
- 11-19: pi is watched as well, through an extension.
- 11-17: osascript's programs are taken out of commands, and JavaScript is laid out.
- 11-16: the agent's edits are marked in your files, and its commands are shown as
  compilations.
- 11-15: vigil: keep what a coding agent did, and show it in Emacs.
