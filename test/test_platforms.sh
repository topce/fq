#!/bin/sh
# End-to-end checks for the Linux and Windows code paths.
#
# They run anywhere — including macOS — because FQ_PLATFORM selects the
# platform implementation and the backends can be fed fixtures:
#
#   * FQ_ENUM_OUTPUT   a file whose contents replace the output of the
#                      enumeration command (tasklist, wmctrl, ...),
#   * FQ_PROC_ROOT     a /proc-like directory tree for the Linux backend,
#   * FQ_DESKTOP_DIRS  where .desktop entries are looked up,
#   * FQ_APPS_FILE     a synthetic application list (see test_sleep.sh),
#   * FQ_SLEEP_CMD     a stub instead of the real sleep command.
#
# The Linux kill path is exercised for real: the fixture /proc tree points at
# processes this script starts, so fq must really SIGKILL them (and leave the
# processes it must not touch alone). The Windows kill path and the Linux sleep
# command are driven with stub taskkill.exe / systemctl executables on PATH.
# Nothing outside the fixtures is ever touched, and the machine is never put
# to sleep.
#
# Usage: test_platforms.sh <path-to-fq-executable>

set -u

FQ=${1:-}
if [ -z "$FQ" ] || [ ! -x "$FQ" ]; then
  echo "usage: $0 <path-to-fq-executable>" >&2
  exit 2
fi

tmp=$(mktemp -d 2>/dev/null || echo /tmp/fq-test-platforms.$$)
mkdir -p "$tmp"
log=$tmp/sleep.log
stub=$tmp/fake-sleep

cat > "$stub" <<'STUB'
#!/bin/sh
printf 'SLEPT\n' >> "$FQ_STUB_LOG"
STUB
chmod +x "$stub"

failures=0
checks=0

# expect <description> <expected-status> <expected-substring|-> <env...> -- <args...>
expect() {
  desc=$1
  want_status=$2
  want_sub=$3
  shift 3
  # environment assignments up to the "--" separator
  envs=""
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do
    envs="$envs $1"
    shift
  done
  [ $# -gt 0 ] && shift
  checks=$((checks + 1))
  out=$(env $envs "$FQ" "$@" 2>&1 </dev/null)
  status=$?
  ok=1
  [ "$status" = "$want_status" ] || ok=0
  if [ "$want_sub" != "-" ]; then
    printf '%s' "$out" | grep -q "$want_sub" || ok=0
  fi
  if [ "$ok" = "1" ]; then
    printf 'ok   %s\n' "$desc"
  else
    failures=$((failures + 1))
    printf 'FAIL %s\n' "$desc"
    printf '     expected status %s and output matching %s, got status %s\n' \
      "$want_status" "$want_sub" "$status"
    printf '     output:\n%s\n' "$out" | sed 's/^/     | /'
  fi
}

# reject <description> <pattern that must not appear> <env...> -- <args...>
reject() {
  desc=$1
  pattern=$2
  shift 2
  envs=""
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do
    envs="$envs $1"
    shift
  done
  [ $# -gt 0 ] && shift
  checks=$((checks + 1))
  out=$(env $envs "$FQ" "$@" 2>&1 </dev/null)
  status=$?
  if [ "$status" = "0" ] && ! printf '%s' "$out" | grep -q "$pattern"; then
    printf 'ok   %s\n' "$desc"
  else
    failures=$((failures + 1))
    printf 'FAIL %s\n' "$desc"
    printf '     expected exit 0 without %s, got exit %s\n' "$pattern" "$status"
    printf '     output:\n%s\n' "$out" | sed 's/^/     | /'
  fi
}

# ---------------------------------------------------------------- fixtures --

# Windows: tasklist /V /FO CSV /NH. Only windowed processes count; explorer is
# a protected system application.
tasklist=$tmp/tasklist.csv
cat > "$tasklist" <<'CSV'
"chrome.exe","1234","Console","1","123,456 K","Running","DOM\user","0:00:01","Google Chrome"
"chrome.exe","1235","Console","1","80,000 K","Running","DOM\user","0:00:00","N/A"
"services.exe","660","Services","0","4,096 K","Running","SYSTEM","0:00:00","N/A"
"notepad.exe","4321","Console","1","12,000 K","Running","DOM\user","0:00:00","Untitled - Notepad"
"explorer.exe","900","Console","1","40,000 K","Running","DOM\user","0:00:00","Program Manager"
CSV

# Linux/X11: wmctrl -lpx (two windows of one application). The client machine
# is this machine: fq drops that column by comparing it with the host name.
wmctrl=$tmp/wmctrl.txt
host=$(hostname 2>/dev/null || uname -n 2>/dev/null || echo localhost)
{
  printf '0x03a00007  0 3041 %s Navigator.Firefox  Mozilla Firefox\n' "$host"
  printf '0x03a0000b  0 3041 %s Navigator.Firefox  Mozilla Firefox (Private)\n' "$host"
  printf '0x05200003  0 5123 %s gnome-terminal-server.Gnome-terminal  user@%s: ~\n' \
    "$host" "$host"
} > "$wmctrl"

# Linux: a synthetic application list used to check the protected names. The
# pids are absurd ones, so a check that stops refusing cannot kill anything.
apps_linux=$tmp/apps-linux.txt
cat > "$apps_linux" <<'APPS'
# pid    name
424247   gnome-shell
424248   systemd
424251   firefox
APPS

# ------------------------------------------------------------------ checks --

# Only the backends of the selected platform are accepted, and an unknown
# platform is refused instead of silently doing the wrong thing.
expect "unsupported platform is refused" 1 "unsupported platform" \
  FQ_PLATFORM=plan9 -- --list
expect "macOS backends are rejected on Linux" 2 "unknown backend" \
  FQ_PLATFORM=linux -- -b lsappinfo --list
expect "Linux backends are rejected on Windows" 2 "unknown backend" \
  FQ_PLATFORM=windows -- -b wmctrl --list
expect "Windows backends are rejected on macOS" 2 "unknown backend" \
  FQ_PLATFORM=macos -- -b procfs --list
expect "the backend list offered matches the platform" 2 "procfs" \
  FQ_PLATFORM=linux -- -b nope --list

# Windows enumeration through tasklist: windowed processes only, ".exe"
# dropped, services and window-less processes hidden.
expect "tasklist backend lists windowed applications" 0 "1234  *chrome" \
  FQ_PLATFORM=windows FQ_ENUM_OUTPUT="$tasklist" -- -b tasklist --list
reject "tasklist backend hides window-less processes" "1235" \
  FQ_PLATFORM=windows FQ_ENUM_OUTPUT="$tasklist" -- -b tasklist --list
reject "tasklist backend hides services" "services" \
  FQ_PLATFORM=windows FQ_ENUM_OUTPUT="$tasklist" -- -b tasklist --list
expect "tasklist backend drops the .exe suffix" 0 "4321  *notepad" \
  FQ_PLATFORM=windows FQ_ENUM_OUTPUT="$tasklist" -- -b tasklist --list
expect "auto picks the platform's first backend" 0 "1234  *chrome" \
  FQ_PLATFORM=windows FQ_ENUM_OUTPUT="$tasklist" -- --list
expect "Windows protected applications are refused" 1 "protected system" \
  FQ_PLATFORM=windows FQ_ENUM_OUTPUT="$tasklist" -- -y explorer

# The Windows kill path (taskkill /PID <pid> /T /F). Driven with a stub
# taskkill.exe on PATH, so the three answers taskkill can give are checked for
# real: the process is gone ("not found" on stderr, exit status 128), it may
# not be killed ("Access is denied"), and it was terminated. The stub is a
# shell script, so on Windows itself the plain check runs instead.
case "$(uname -s 2>/dev/null)" in
  MINGW* | MSYS* | CYGWIN*) taskkill_stub=no ;;
  *) taskkill_stub=yes ;;
esac

apps_win=$tmp/apps-win.txt
printf '424242  Fixture App\n' > "$apps_win"

if [ "$taskkill_stub" = "yes" ]; then
  stubdir=$tmp/bin
  mkdir -p "$stubdir"

  cat > "$stubdir/taskkill.exe" <<'STUB'
#!/bin/sh
printf 'ERROR: The process "424242" not found.\n' >&2
exit 128
STUB
  chmod +x "$stubdir/taskkill.exe"
  expect "taskkill: a process that is gone counts as gone, not as an error" 0 \
    "no longer running" FQ_PLATFORM=windows FQ_APPS_FILE="$apps_win" \
    PATH="$stubdir:$PATH" -- -y "Fixture App"

  cat > "$stubdir/taskkill.exe" <<'STUB'
#!/bin/sh
printf 'ERROR: Access is denied.\n' >&2
exit 1
STUB
  chmod +x "$stubdir/taskkill.exe"
  expect "taskkill: access denied is reported as such" 1 "Administrator" \
    FQ_PLATFORM=windows FQ_APPS_FILE="$apps_win" PATH="$stubdir:$PATH" -- \
    -y "Fixture App"

  cat > "$stubdir/taskkill.exe" <<'STUB'
#!/bin/sh
printf 'SUCCESS: The process "424242" has been terminated.\n'
exit 0
STUB
  chmod +x "$stubdir/taskkill.exe"
  expect "taskkill: a terminated process is reported as force-quit" 0 \
    "Force-quit" FQ_PLATFORM=windows FQ_APPS_FILE="$apps_win" \
    PATH="$stubdir:$PATH" -- -y "Fixture App"
else
  checks=$((checks + 1))
  out=$(FQ_PLATFORM=windows FQ_APPS_FILE="$apps_win" "$FQ" -y "Fixture App" 2>&1 </dev/null)
  status=$?
  if { [ "$status" = "0" ] && printf '%s' "$out" | grep -q "no longer running"; } ||
     { [ "$status" = "1" ] && printf '%s' "$out" | grep -q "taskkill"; }; then
    printf 'ok   Windows kill path reports a gone process (or a missing taskkill)\n'
  else
    failures=$((failures + 1))
    printf 'FAIL Windows kill path: exit %s\n' "$status"
    printf '     output:\n%s\n' "$out" | sed 's/^/     | /'
  fi
fi

# Linux enumeration through wmctrl.
expect "wmctrl backend lists windows as applications" 0 "3041  *Firefox" \
  FQ_PLATFORM=linux FQ_ENUM_OUTPUT="$wmctrl" -- -b wmctrl --list
expect "wmctrl backend appends the fallback backend to the list" 0 "procfs" \
  FQ_PLATFORM=linux -- --help
expect "Linux protected applications are refused" 1 "protected system" \
  FQ_PLATFORM=linux FQ_APPS_FILE="$apps_linux" -- -y gnome-shell
expect "Linux protected applications are refused by name too" 1 "protected system" \
  FQ_PLATFORM=linux FQ_APPS_FILE="$apps_linux" -- -y systemd
expect "Linux sleep uses the platform's own command" 0 "systemctl suspend" \
  FQ_PLATFORM=linux -- --help

# Without FQ_SLEEP_CMD, -s on Linux must run `systemctl suspend` itself. The
# stub records the call and exits 0, so the machine stays awake.
sleepstub=$tmp/bin-linux
mkdir -p "$sleepstub"
cat > "$sleepstub/systemctl" <<'STUB'
#!/bin/sh
printf 'SUSPEND %s\n' "$*" >> "$FQ_STUB_LOG"
STUB
chmod +x "$sleepstub/systemctl"
apps_none=$tmp/apps-none.txt
printf '# nothing running\n' > "$apps_none"
checks=$((checks + 1))
rm -f "$log"
env FQ_PLATFORM=linux FQ_APPS_FILE="$apps_none" FQ_STUB_LOG="$log" \
  PATH="$sleepstub:$PATH" "$FQ" -o -y -s >/dev/null 2>&1
if [ -f "$log" ] && grep -q "SUSPEND suspend" "$log"; then
  printf 'ok   Linux sleep really runs systemctl suspend\n'
else
  failures=$((failures + 1))
  printf 'FAIL Linux sleep did not run systemctl suspend\n'
  [ -f "$log" ] && sed 's/^/     | /' "$log"
fi

# The Linux /proc backend and its kill path, driven with real processes.
if command -v python3 >/dev/null 2>&1; then
  helper=$tmp/procfs-e2e.py
  cat > "$helper" <<'PY'
import os, sys, time

fq, tmp = sys.argv[1], sys.argv[2]
root = os.path.join(tmp, "proc")
desktop = os.path.join(tmp, "applications")
os.makedirs(root, exist_ok=True)
os.makedirs(desktop, exist_ok=True)

GRAPHICAL = b"DISPLAY=:0\x00HOME=/home/user\x00"
PLAIN = b"HOME=/home/user\x00"


def write_desktop(name, exe):
    with open(os.path.join(desktop, name + ".desktop"), "w") as f:
        f.write("[Desktop Entry]\nType=Application\nName=%s\nExec=%s %%U\n"
                % (name.replace("-", " ").title(), exe))


def proc_entry(pid, comm, ppid, pgrp, tty_nr, environ, exe):
    d = os.path.join(root, str(pid))
    os.makedirs(d, exist_ok=True)
    # pid (comm) state ppid pgrp session tty_nr tpgid ...
    with open(os.path.join(d, "stat"), "w") as f:
        f.write("%d (%s) S %d %d %d %d 0 -1 4194304 1 0 0 0 0 0 20 0 1 0 1 0\n"
                % (pid, comm, ppid, pgrp, pgrp, tty_nr))
    with open(os.path.join(d, "environ"), "wb") as f:
        f.write(environ)
    if exe:
        try:
            os.symlink(exe, os.path.join(d, "exe"))
        except FileExistsError:
            pass


def spawn(own_group, marker):
    """Start `sleep 30' plus one child; the child records its pid."""
    r, w = os.pipe()
    pid = os.fork()
    if pid == 0:
        os.close(r)
        if own_group:
            os.setpgid(0, 0)
        kid = os.fork()
        if kid == 0:
            with open(marker, "w") as f:
                f.write(str(os.getpid()))
            time.sleep(30)
            os._exit(0)
        os.write(w, b"x")
        time.sleep(30)
        os._exit(0)
    os.close(w)
    os.read(r, 1)
    os.close(r)
    # wait for the grandchild to write its pid
    for _ in range(100):
        if os.path.exists(marker):
            with open(marker) as f:
                kid = int(f.read().strip())
            return pid, kid
        time.sleep(0.05)
    raise SystemExit("child never announced itself")


leader, leader_kid = spawn(True, os.path.join(tmp, "leader-child.pid"))
solo, solo_kid = spawn(False, os.path.join(tmp, "solo-child.pid"))
infra = os.fork()
if infra == 0:
    time.sleep(30)
    os._exit(0)
background = os.fork()
if background == 0:
    time.sleep(30)
    os._exit(0)

write_desktop("leader-app", "/opt/leader-app")
write_desktop("solo-app", "/opt/solo-app")
proc_entry(leader, "leader-app", 1, leader, 0, GRAPHICAL, "/opt/leader-app")
proc_entry(leader_kid, "leader-app", leader, leader, 0, GRAPHICAL, "/opt/leader-app")
proc_entry(solo, "solo-app", os.getpid(), os.getpgrp(), 0, GRAPHICAL, "/opt/solo-app")
proc_entry(solo_kid, "solo-app", solo, os.getpgrp(), 0, GRAPHICAL, "/opt/solo-app")
# session infrastructure: in a graphical session, but never an application
proc_entry(infra, "gnome-shell", 1, infra, 0, GRAPHICAL, "/usr/bin/gnome-shell")
# a background program with no graphical session: not an application either
proc_entry(background, "make", 1, background, 0, PLAIN, "/usr/bin/make")

fails = []


def fate(pid):
    """`killed' (SIGKILL), `gone', `exited' or `alive' -- a child of ours that
    was SIGKILLed stays visible to kill(pid, 0) until it is reaped."""
    try:
        wpid, status = os.waitpid(pid, os.WNOHANG)
    except ChildProcessError:
        try:
            os.kill(pid, 0)
            return "alive"
        except OSError:
            return "gone"
    if wpid == 0:
        return "alive"
    if os.WIFSIGNALED(status) and os.WTERMSIG(status) == 9:
        return "killed"
    return "exited"


env = dict(os.environ)
env["FQ_PLATFORM"] = "linux"
env["FQ_PROC_ROOT"] = root
env["FQ_DESKTOP_DIRS"] = desktop
env.pop("FQ_APPS_FILE", None)

import re
import subprocess

listing = subprocess.run([fq, "--list"], env=env, capture_output=True, text=True)
out = listing.stdout
if listing.returncode != 0:
    fails.append("--list failed: %s%s" % (out, listing.stderr))
if not re.search(r"^%d\s+Leader App$" % leader, out, re.M):
    fails.append("Leader App missing from --list:\n%s" % out)
if not re.search(r"^%d\s+Solo App$" % solo, out, re.M):
    fails.append("Solo App missing from --list:\n%s" % out)
if "gnome-shell" in out or "make" in out:
    fails.append("infrastructure or non-graphical processes were listed:\n%s" % out)
if str(leader_kid) in out:
    fails.append("a helper process was listed as an application:\n%s" % out)

run = subprocess.run([fq, "-o", "-y", "-s"], env=env, capture_output=True, text=True)
if run.returncode != 0:
    fails.append("--others failed (%d): %s" % (run.returncode, run.stderr))

# every application of the fixture must be gone, killed with SIGKILL
for name, pid in [("leader", leader), ("leader child", leader_kid),
                  ("solo", solo), ("solo child", solo_kid)]:
    what = fate(pid)
    if what not in ("killed", "gone"):
        fails.append("%s (pid %d) survived the force-quit (%s)" % (name, pid, what))
        try:
            os.kill(pid, 9)
        except OSError:
            pass
# the processes fq must not touch have to be running still
for name, pid in [("session infrastructure", infra), ("background build", background)]:
    what = fate(pid)
    if what != "alive":
        fails.append("%s (pid %d) was force-quit (%s)" % (name, pid, what))

for pid in (leader, leader_kid, solo, solo_kid, infra, background):
    try:
        os.kill(pid, 9)
    except OSError:
        pass
    try:
        os.waitpid(pid, 0)
    except OSError:
        pass

if fails:
    for f in fails:
        sys.stderr.write(f + "\n")
    sys.exit(1)
sys.exit(0)
PY

  checks=$((checks + 1))
  rm -f "$log"
  if FQ_SLEEP_CMD="$stub" FQ_STUB_LOG="$log" python3 "$helper" "$FQ" "$tmp" \
      >"$tmp/e2e.log" 2>&1; then
    got=0
    [ -f "$log" ] && got=$(wc -l < "$log" | tr -d ' ')
    if [ "$got" = "1" ]; then
      printf 'ok   procfs backend: lists, kills and sleeps (end to end)\n'
    else
      failures=$((failures + 1))
      printf 'FAIL procfs backend: expected 1 sleep call, got %s\n' "$got"
    fi
  else
    failures=$((failures + 1))
    printf 'FAIL procfs backend end-to-end\n'
    sed 's/^/     | /' "$tmp/e2e.log"
  fi
else
  printf 'skip procfs end-to-end checks (python3 unavailable)\n'
fi

rm -rf "$tmp"

if [ "$failures" -gt 0 ]; then
  printf '%s/%s platform checks failed\n' "$failures" "$checks"
  exit 1
fi
printf 'all %s platform checks passed\n' "$checks"
