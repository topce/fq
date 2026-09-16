# fq — force-quit applications from the command line

`fq` lists the running GUI applications and force-quits the chosen one: no
chance to save work, helper processes taken down with the app.

The command line is the same everywhere; the implementation is not:

| | macOS | Linux | Windows |
| --- | --- | --- | --- |
| **Enumeration** | `lsappinfo` (exactly the apps the **Force Quit** dialog shows), `osascript` fallback | `/proc` scan of the graphical session (no external tools), `wmctrl -lpx` alternative | `tasklist` (windowed processes), PowerShell `Get-Process` alternative |
| **Kill** | `SIGKILL` to the process group | `SIGKILL` to the process group, or to the process tree | `taskkill /T /F` (the process tree) |
| **Sleep (`-s`)** | `pmset sleepnow` | `systemctl suspend`, `pm-suspend`, `zzz` | `SetSuspendState('Suspend')`, `rundll32` fallback |
| **Protected system apps** | Finder, loginwindow, WindowManager, Dock, … | session shell, window manager, compositors, session daemons | Explorer, DWM, csrss/winlogon/services/… |

On macOS it mirrors the system **Force Quit** dialog (⌥⌘⎋) exactly. On Linux
and Windows it does the same job with the platform's own facilities: the
applications of your graphical session are enumerated and a victim is killed
together with the processes that belong to it.

It is written in OCaml (stdlib + `unix` only, no third-party dependencies).

## Installation

| Platform | Channel | Command |
| --- | --- | --- |
| macOS | Homebrew [tap](https://github.com/topce/homebrew-fq) | `brew install topce/fq/fq` |
| macOS, Linux | opam | `opam install fq` |
| Arch Linux | AUR | `paru -S fq` (or `yay -S fq`) |
| Windows | WinGet | `winget install Topce.Fq` |
| Windows | Scoop | `scoop bucket add topce https://github.com/topce/scoop-bucket` then `scoop install topce/fq` |
| any | from source | see below |

Release binaries (tarballs for Linux/macOS, a zip for Windows, with
`SHA256SUMS` and a build-provenance attestation) are attached to every
[GitHub release](https://github.com/topce/fq/releases):

```sh
# Linux, glibc ≥ 2.35 (Ubuntu 22.04+, Debian 12+, RHEL 9+)
curl -LO https://github.com/topce/fq/releases/latest/download/fq-0.4.0-linux-x86_64.tar.gz
tar -xzf fq-0.4.0-linux-x86_64.tar.gz
sudo install -m755 fq-0.4.0-linux-x86_64/fq /usr/local/bin/fq
gh attestation verify fq-0.4.0-linux-x86_64.tar.gz --repo topce/fq   # optional
```

A `-linux-x86_64-static` build (musl) is published alongside it for Alpine,
NixOS and anywhere the glibc version is a problem, and Windows on ARM runs the
x64 zip through emulation. The Homebrew formula builds from source with
Homebrew's ocaml + dune — OCaml stdlib + `unix` only, so the build takes
seconds.

> **Name clash:** an unrelated message broker is also published as `fq` in
> homebrew-core, so plain `brew install fq` installs *that* tool. Always use
> the fully qualified `brew install topce/fq/fq`.

> The WinGet, Scoop, AUR and opam entries are published from `packaging/` by
> the release process described in [docs/RELEASING.md](docs/RELEASING.md). When
> a channel is not live yet for the version you want, build from source.
> Windows binaries are currently unsigned, so SmartScreen warns on first run —
> check the sha256 in `SHA256SUMS` before running them.

**From source** (requires OCaml ≥ 5 and dune; on Windows use a native OCaml
≥ 5.1 with opam 2.2+):

```sh
git clone https://github.com/topce/fq && cd fq
dune build            # builds bin/main.exe
dune install          # after: opam install .
```

Everything fq calls at runtime (`lsappinfo`, `wmctrl`, `tasklist`, `taskkill`,
`powershell`, `pmset`, `systemctl`) ships with the operating system except
`wmctrl`, which is an optional alternative backend on Linux — the default
Linux backend needs nothing beyond `/proc`.

## Usage

```
fq [OPTIONS] [APP]

  fq                       pick application(s) interactively: type a number,
                           or comma-separated numbers (e.g. 1,3,5) to force
                           quit several at once
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
  fq -s "Safari"           force quit Safari, then put the machine to sleep
  fq --others -y -s        force quit every other app, then put the machine to
                           sleep — this terminal keeps running, and the machine
                           is put to sleep even if there was nothing else to
                           quit
  fq --all -y -s           force quit everything (this terminal included),
                           then put the machine to sleep
```

Every force-quit is confirmed before it happens (`fq -y` skips the
confirmation).

In the interactive picker, instead of one number you can type a
comma-separated list of numbers — `1,3,5` — to force quit those applications
in one go. Duplicates (`1,1,3`) are ignored and the batch is confirmed once
before anything is killed.

Prompts take single keys on a real terminal: Return submits, and **Escape**
cancels immediately — no need to press Return afterwards (when stdin is
redirected, whole lines are read instead, so scripting is unchanged; on
Windows consoles, which have no single-key mode, whole lines are read too).

## Options

| Option | Meaning |
| --- | --- |
| `-l`, `--list` | list running applications as `pid name` and exit |
| `-a`, `--all` | force quit every running application (protected system ones are skipped — see below) |
| `-o`, `--others` | force quit every running application except the application running this terminal and the protected system ones |
| `-p`, `--pid PID` | force quit the process with this PID |
| `-s`, `--sleep` | after force-quitting, also put the machine to sleep — also when there was nothing to quit |
| `-y`, `--yes` | force quit without asking for confirmation |
| `-f`, `--force` | also allow force-quitting protected system applications |
| `-b`, `--backend BACKEND` | enumeration backend — only the backends of the current platform are accepted: `lsappinfo` (macOS, default), `osascript` (macOS), `procfs` (Linux, default), `wmctrl` (Linux/X11), `tasklist` (Windows, default), `powershell` (Windows) |
| `-h`, `--help` | show help and exit |
| `-V`, `--version` | show version and exit |

Options and an `APP` argument are mutually exclusive: pass one application
name, `--pid`, `--list`, `--all`, or `--others` — not several.

## What is listed

* **macOS** — only regular GUI applications (`type="Foreground"` in
  `lsappinfo` terms), i.e. the same apps the Force Quit dialog shows.
  Dock/menu-bar agents (`UIElement`) and background processes
  (`BackgroundOnly`) are hidden. No Automation/Accessibility (TCC) permission
  is needed; System Events via `osascript` is the fallback (`-b osascript`).
* **Linux** — the applications of the current graphical session, read from
  `/proc`: a process counts as an application when it runs with `DISPLAY` or
  `WAYLAND_DISPLAY` set, is not a console program (not the job a terminal is
  running in the foreground, not a shell — an application started with
  `app &` or detached from its terminal does count, which is how desktop
  environments and launchers start applications), and is not session
  infrastructure (window manager, compositor, panels, session/sound daemons,
  portals, input methods). Helper processes of a multi-process application —
  a browser's renderer processes, say — run the application's own binary and
  are folded into it, so the list shows applications, not processes. Names
  come from the matching `.desktop` entry when there is one (searched in
  `/usr/share/applications`, `/usr/local/share/applications`,
  `~/.local/share/applications` and the Flatpak exports). On X11,
  `-b wmctrl` lists the windows on screen instead, which is the closest
  match to the Force Quit dialog but needs `wmctrl` installed and misses
  window-less applications.
* **Windows** — the processes with a window, via `tasklist /V`; the image
  name without `.exe` is the application name. Applications without a window
  (tray-only helpers) are not listed, and Administrator rights are needed to
  see the processes of other users. `-b powershell` uses
  `Get-Process`/`MainWindowTitle` instead.

## How it kills

* **macOS** — the main process is sent `SIGKILL` immediately, exactly like
  clicking *Force Quit*. Multi-process applications launched by LaunchServices
  lead their own process group (verified via `ps`), so the whole group is
  killed and a browser's renderer/helper processes die with the main app. If a
  process does not lead its own group, only that process is killed, so
  unrelated processes sharing a terminal's group are never touched.
* **Linux** — the same group kill, but when the victim does not lead its own
  process group (an application started in the foreground of a terminal, say)
  its whole process tree is killed from `/proc` instead — the equivalent of
  `taskkill /T`. fq's own process, its ancestors and its process group are
  never signalled.
* **Windows** — `taskkill /PID <pid> /T /F`, which terminates the process
  tree, helpers included.

Only your own user's processes can be killed without `sudo` (Linux/macOS) or
Administrator rights (Windows).

## Protected applications

`fq` refuses to force-quit the core processes of the current session unless
`-f/--force` is given:

* **macOS**: Finder, loginwindow, WindowManager, Dock, SystemUIServer,
  Control Center, Notification Center. Finder appears in listings and the
  interactive picker marks it `(protected)`.
* **Linux**: the session shell (gnome-shell, plasmashell, …), the window
  managers and compositors (mutter, kwin, xfwm4, sway, …), `Xorg`/`Xwayland`,
  `systemd`/`init`, the session managers (gnome-session, ksmserver, …), the
  bus and sound daemons (dbus-daemon, pipewire, wireplumber, pulseaudio) and
  the display managers.
* **Windows**: Explorer, the Desktop Window Manager (`dwm`), and the session
  processes `winlogon`, `csrss`, `wininit`, `services`, `lsass`, `smss`,
  `sihost`, `taskhostw`, `ctfmon`, `svchost`, `RuntimeBroker`, …

`--all` skips protected applications unless `-f` is also given.

## This terminal is never killed

`--others` force-quits every running application except the protected ones
and the application running fq itself — the terminal (or terminal emulator)
that hosts the session fq was launched in. That app is found by walking the
process tree upward from fq (`ps` on macOS/Linux, the Windows process table
via PowerShell), so killing it (which would also kill your session) is never
done, even with `-f/--force`. fq's own process group is protected in the same
way: a process that leads or shares fq's group is never force-quit by
`--others`, and no force-quit ever signals fq's own group — that would kill
the "self process" (fq) before it could finish, e.g. before the sleep
requested with `-s`. `--all` has no such safeguard for the *application*
running the terminal: from a terminal it force-quits the terminal too (but
still not fq's own process group, so the sleep always happens).

If the process tree cannot be read at all — no `ps(1)`, PowerShell blocked,
`/proc` not mounted — `--others` says so, because the application running the
terminal cannot be recognised without it.

## Put the machine to sleep (-s/--sleep)

`-s/--sleep` puts the machine to sleep once the requested force-quits have
all succeeded — handy before walking away from the machine. The confirmation
asks for both together ("… and put the computer to sleep?"), and if any
force-quit fails the machine is *not* put to sleep and fq exits 1.

The sleep is a step of its own, so it happens even when there was nothing to
quit: `fq --others -y -s` from a terminal whose application is protected (or
is the only thing left running) still puts the machine to sleep after
reporting that there was nothing else to quit. Without `-y`, and with nothing
to quit, fq asks about the sleep on its own ("Put the computer to sleep?
[y/N]") rather than asking to force-quit zero applications.

When the force-quit list includes the application running this terminal
(`--all`, or picking the terminal itself in the interactive list), that app is
force-quit last: a fully detached helper is armed just beforehand and performs
the sleep, so the machine still goes to sleep even if killing the terminal
takes fq down with it (a `setsid` shell on macOS/Linux, a hidden detached
PowerShell script on Windows).

`FQ_SLEEP_CMD` overrides the sleep command, which is how the tests keep the
machine awake.

## Exit status

| Code | Meaning |
| --- | --- |
| `0` | everything requested was force-quit or already gone; nothing was done |
| `1` | error (application not found, permission denied, a force-quit failed, …) |
| `2` | usage error |

## Building and testing

Requires OCaml ≥ 5 and dune.

```
dune build            # build the fq executable (bin/main.exe)
dune exec fq -- -l    # run it
dune runtest          # unit tests (parsers, name matching, /proc, .desktop)
                      # plus the end-to-end sleep and platform checks
dune install          # install into ~/.opam/.../bin (after opam install .)
```

`dune runtest` never quits a real application, never touches a process outside
its fixtures, and never puts the machine to sleep. The Linux and Windows code
paths are driven on any developer machine through environment hooks:

| Variable | Effect |
| --- | --- |
| `FQ_PLATFORM` | `macos`, `linux` or `windows`: use that platform's implementation and backends |
| `FQ_APPS_FILE` | replace enumeration with a file of `pid name` lines |
| `FQ_ENUM_OUTPUT` | replace the output of the enumeration command (`tasklist`, `wmctrl`, `lsappinfo`, …) with a file's contents |
| `FQ_PROC_ROOT` | a `/proc`-like tree to enumerate (the Linux backend) |
| `FQ_DESKTOP_DIRS` | where `.desktop` entries are looked up (`:`-separated) |
| `FQ_SLEEP_CMD` | the command used instead of the real sleep command |

`test/test_platforms.sh` uses them to exercise the Linux backend against a
synthetic `/proc` tree whose pids are processes the test starts itself: fq
must really SIGKILL the applications (group kill and tree kill) and must leave
session infrastructure and non-graphical processes alone. The same script
drives the Windows kill path with stub `taskkill.exe` executables on `PATH`
(a gone process, access denied, a terminated process) and checks that `-s` on
Linux really runs `systemctl suspend`, with a stub that keeps the machine
awake.

## Layout

* `lib/fq.ml[i]` — library: platform detection, app enumeration backends
  (`lsappinfo`, `osascript`, `/proc`, `wmctrl`, `tasklist`, PowerShell),
  parsers, `.desktop` lookup, name matching, process introspection and the
  kill/sleep implementations per platform. Backends and parsers are pure
  functions, unit-tested in `test/`.
* `bin/main.ml` — CLI: arg parsing, interactive picker, confirmation, output,
  platform-aware help.
* `test/test_fq.ml` — unit tests (fixture-driven parsers, the `/proc`
  enumeration against a temporary fixture tree, name matching, process-tree
  helpers).
* `test/test_sleep.sh` — end-to-end `-s/--sleep` checks against the built
  executable, using a synthetic application list and a stub sleep command.
* `test/test_platforms.sh` — end-to-end checks for the Linux and Windows code
  paths (backend selection, protected names, the real Linux kill path against
  fixture processes, the stubbed Windows kill path and Linux sleep command).
* `.github/workflows/` — CI on Linux, macOS and Windows, and the release
  pipeline that builds, tests, packages, checksums and attests the binaries on
  a `vX.Y.Z` tag.
* `packaging/` — release manifests for the other channels (Homebrew, Scoop,
  WinGet, AUR, nfpm) and `packaging/render.sh`, which fills them in from a
  published `SHA256SUMS`.
* `docs/RELEASING.md` — the release runbook: channels, canary stage,
  verification, rollback and monitoring.

## Notes

* Force-quitting is destructive by design (that is the point). Use `-y` only
  when you mean it — interactive, name/pid, and `--all` modes confirm before
  anything is killed.
* Listing is a best-effort heuristic on Linux and Windows: it aims for the
  applications a user recognises, not for a kernel-level truth. `-b wmctrl`
  (Linux/X11) lists exactly what is on screen; `-b powershell` (Windows) uses
  `MainWindowTitle` instead of `tasklist`.
* macOS-only wording in older documentation ("Force Quit dialog") refers to
  the corresponding feature of each platform: Task Manager's *End task* on
  Windows, the desktop environment's own "force quit" on Linux.
