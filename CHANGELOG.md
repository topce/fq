# Changelog

All notable changes to fq are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.0] - 2026-09-13

### Fixed

- `-s/--sleep` is no longer skipped when there is nothing to force-quit. Every
  mode that found zero victims exited before reaching the sleep code, so
  `fq -o -y -s` — the natural "quit everything else, then sleep" command —
  silently did nothing at all when every other application was protected or
  the application running the terminal was the only one left. The sleep is now
  a step of its own that every mode reaches; with nothing to quit and without
  `-y`, fq asks about the sleep alone ("Put the Mac to sleep? [y/N]") instead
  of asking to force-quit zero applications.
- The sleep is no longer asked for twice: the combined "force quit … and put
  the Mac to sleep?" confirmation now covers the sleep, so a single `y` both
  quits and sleeps. This was still broken when naming an application on the
  command line (`fq -s Safari`), which asked a second time after the first `y`
  and then treated the second, unanswered prompt as a decline — so the Mac was
  never put to sleep.

### Added

- `FQ_SLEEP_CMD` overrides the program used to put the Mac to sleep, and
  `FQ_APPS_FILE` (`pid name` lines) overrides application enumeration. Both
  exist so the test suite can exercise the real code paths without touching
  running applications or actually sleeping the machine.

### Tests

- `test/test_sleep.sh` covers the sleep behaviour end to end, driven through
  the built executable with a synthetic application list and a stub sleep
  command: nothing-to-quit still sleeps (including a machine with no
  applications at all), one confirmation never asks twice (for `--others`,
  `--pid`, and a named application alike), a declined confirmation never
  sleeps, and a refused protected application exits 1 without sleeping.

## [0.2.0] - 2026-09-08

### Added

- `-s/--sleep`: once the requested force-quits have succeeded, put the Mac
  to sleep (`pmset sleepnow`). The confirmation asks for both together
  ("… and put the Mac to sleep?"); a failed force-quit skips the sleep and
  exits 1. When the application running this terminal is among the victims
  it is force-quit last and the sleep is handed to a detached helper armed
  just beforehand, so the Mac still goes to sleep even if fq is taken down
  with its terminal.
- The interactive picker accepts comma-separated numbers — `1,3,5` — to
  force quit several applications in one go. Duplicates are ignored and the
  batch is confirmed once before anything is killed. Protected system
  applications in the batch are refused unless `-f/--force` is given.
- Prompts read single keys on a real terminal: Return submits, and Escape
  (or ^D) cancels immediately — no Return needed afterwards. When stdin is
  redirected, whole lines are read instead, so scripting is unchanged.

## [0.1.0] - 2026-09-07

### Added

- Initial release. List running GUI applications (via `lsappinfo(1)`, with
  an `osascript` fallback), force quit one by name, by PID, or interactively,
  plus `--all`/`--others` bulk modes — mirroring the macOS Force Quit dialog
  (⌥⌘⎋): SIGKILL to the main process, whole process group taken down.
- Protected system applications (Finder, loginwindow, Dock, …) are refused
  unless `-f/--force` is given; the application running this terminal is
  never force-quit by `--others`.
- Interactive confirmation before every force-quit; `-y/--yes` skips it.
- Written in OCaml stdlib + `unix` only — no third-party dependencies.
