# fq — force-quit macOS applications from the command line

`fq` lists the running GUI applications on macOS and force-quits the chosen
one with `SIGKILL`, mirroring the behaviour of the system **Force Quit**
dialog (⌥⌘⎋): no chance to save work, helpers taken down with the app.

It is written in OCaml (stdlib + `unix` only, no third-party dependencies).

## Usage

```
fq [OPTIONS] [APP]

  fq                       pick an application interactively
  fq "Safari"              force quit Safari (asks for confirmation)
  fq -y firefox            non-interactive force quit
  fq --list                list running apps as "pid name"
  fq --all                 force quit every app except protected system ones
  fq --all -y              same, non-interactive
  fq --all -f              ... including the protected system ones (risky)
  fq --others              force quit every other app: this terminal and the
                           protected system ones keep running
  fq --others -y           same, non-interactive
  fq --others -f           ... but also quit the protected system ones
  fq -p 1234               force quit by PID
```

Every force-quit is confirmed before it happens (`fq -y` skips the
confirmation).

## Options

| Option | Meaning |
| --- | --- |
| `-l`, `--list` | list running applications as `pid name` and exit |
| `-a`, `--all` | force quit every running application (protected system ones are skipped — see below) |
| `-o`, `--others` | force quit every running application except the application running this terminal and the protected system ones |
| `-p`, `--pid PID` | force quit the process with this PID |
| `-y`, `--yes` | force quit without asking for confirmation |
| `-f`, `--force` | also allow force-quitting protected system applications |
| `-b`, `--backend BACKEND` | enumeration backend: `lsappinfo` (default) or `osascript` |
| `-h`, `--help` | show help and exit |
| `-V`, `--version` | show version and exit |

Options and an `APP` argument are mutually exclusive: pass one application
name, `--pid`, `--list`, `--all`, or `--others` — not several.

## Protected applications

`fq` refuses to force-quit core system processes — Finder, loginwindow,
WindowManager, Dock, SystemUIServer, Control Center, Notification Center —
unless `-f/--force` is given. Finder appears in listings and the interactive
picker marks it `(protected)`, but it cannot be force-quit without `-f`.
`--all` skips protected applications unless `-f` is also given.

## This terminal is never killed

`--others` force-quits every running application except the protected ones and
the application running fq itself — the GUI app that hosts the terminal fq
was launched in. That app is found by walking the process tree upward from
fq (`ps`), so killing it (which would also kill your session) is never done,
even with `-f/--force`. `--all` has no such safeguard: from a terminal it
force-quits the terminal too.

## Exit status

| Code | Meaning |
| --- | --- |
| `0` | everything requested was force-quit or already gone; nothing was done |
| `1` | error (application not found, permission denied, …) |
| `2` | usage error |

## How it mirrors the Force Quit dialog

* **What is listed** — only regular GUI applications (`type="Foreground"` in
  `lsappinfo` terms), i.e. the same apps the dialog shows. Dock/menu-bar
  agents (`UIElement`) and background processes (`BackgroundOnly`) are hidden.
* **How it kills** — the main process is sent `SIGKILL` immediately, exactly
  like clicking *Force Quit*.
* **Multi-process apps** — applications launched by LaunchServices lead their
  own process group (verified via `ps`), so the whole group is killed: a
  browser's renderer/helper processes die with the main app. If a process does
  not lead its own group, only that process is killed, so unrelated processes
  sharing a terminal's group are never touched.
* **No permissions prompt** — applications are enumerated with `lsappinfo(1)`,
  which needs no Automation/Accessibility (TCC) permission. System Events via
  `osascript` is used as a fallback (`-b osascript`).

Name matching is case-insensitive, ignores a trailing `.app`, and accepts an
unambiguous substring (`fq fire` matches “Firefox Developer Edition”).

## Building and testing

Requires OCaml ≥ 5 and dune.

```
dune build            # build the fq executable (bin/main.exe)
dune exec fq -- -l    # run it
dune runtest          # unit tests (parsers, name matching)
dune install          # install into ~/.opam/.../bin (after opam install .)
```

## Layout

* `lib/fq.ml[i]` — library: app enumeration (lsappinfo/osascript), parsers,
  name matching, SIGKILL/process-group logic. Backends and parsers are pure
  functions, unit-tested in `test/`.
* `bin/main.ml` — CLI: arg parsing, interactive picker, confirmation, output.
* `test/test_fq.ml` — unit tests (fixture-driven parsers plus
  self-referential process-tree checks that need no fixed PIDs).

## Notes

* Force-quitting is destructive by design (that is the point). Use `-y` only
  when you mean it; interactive, name/pid, and `--all` modes confirm by
default.
* Only your own user's processes can be killed without `sudo`.
* macOS-only (relies on `lsappinfo`, `ps`, `uname`).
