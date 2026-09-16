# Changelog

All notable changes to fq are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.4.0] - 2026-09-16

### Added

- **Linux support.** Applications are enumerated from `/proc`: a process is an
  application when it runs in a graphical session (`DISPLAY`/`WAYLAND_DISPLAY`),
  does not belong to a terminal (it is neither a shell nor the job a terminal
  is running in the foreground — an application started with `app &` or
  detached from its terminal counts) and is not session infrastructure (window
  manager, compositors, panels, session/sound daemons, portals, input methods).
  Helper
  processes of a multi-process application run the application's own binary and
  are folded into it, and applications are named after their `.desktop` entry
  when there is one. Victims are killed as a process group, or — for a process
  that does not lead its own group — as a whole process tree read from `/proc`.
  `-b wmctrl` lists the windows on screen instead (X11).
- **Windows support.** Applications are enumerated with `tasklist /V` (windowed
  processes; the image name without `.exe`), with PowerShell `Get-Process` as
  the alternative backend. Victims are terminated with `taskkill /PID <pid>
  /T /F`, helpers included. The process tree is read once with PowerShell for
  the "this terminal is never killed" logic.
- Platform-specific sleep commands: `systemctl suspend` (with `pm-suspend` and
  `zzz` as fallbacks) on Linux and `SetSuspendState('Suspend')` (with
  `rundll32` as a fallback) on Windows. On Windows the detached helper that
  guarantees the sleep when the terminal itself is force-quit is a hidden,
  detached PowerShell script.
- Platform-specific protected system applications: the session shell, window
  managers and session daemons on Linux; Explorer, the desktop window manager
  and the core session processes on Windows.
- `-b/--backend` accepts the backends of the running platform only, and an
  unsupported platform is refused with a clear message instead of failing
  somewhere deeper.
- The help text, prompts and messages are platform-aware ("put the Mac to
  sleep", "put the computer to sleep", "put the PC to sleep").
- Packaging for every channel: `packaging/` renders the Homebrew, Scoop,
  WinGet, AUR and nfpm manifests from a `SHA256SUMS` file, and
  `docs/RELEASING.md` is the release runbook (tagging, the package managers,
  building the optional archives by hand, canary stage, verification,
  rollback, monitoring).
- Test hooks for driving the non-native code paths anywhere: `FQ_PLATFORM`,
  `FQ_ENUM_OUTPUT`, `FQ_PROC_ROOT` and `FQ_DESKTOP_DIRS` (documented in the
  README), plus `test/test_platforms.sh`, which exercises the Linux backend
  and its real kill path against a synthetic `/proc` tree.

### Changed

- A failed force-quit now always exits 1. Previously the exit status was only
  turned into 1 by `-s/--sleep`; without it, a force-quit that failed (a
  permission error, say) reported the failure but exited 0, contradicting the
  documented exit status.
- `FQ_APPS_FILE` is read directly instead of with `cat`, so the test hooks work
  on Windows too.

## [0.3.1] - 2026-09-13

### Fixed

- `--others` no longer kills fq's own process group — the "self process". If an
  application in the list led fq's process group (so it was not an ancestor),
  fq treated it as a victim and sent `SIGKILL` to the whole group, taking
  itself down with it; the requested `-s/--sleep` then never happened. The
  process-group leader is now treated as self by `--others`, and
  `force_quit_pid` never signals fq's own process group or pid, so the sleep
  (and anything else still to do) always runs. With no other application to
  quit, `-o -y -s` still puts the Mac to sleep.

### Tests

- `test/test_sleep.sh` now also covers the self-process case: fq is placed in
  a process group led by a non-ancestor application and `-o -y -s` must leave
  that application running and still put the Mac to sleep. `test/test_fq.ml`
  checks that a force-quit refuses fq's own pid.

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
