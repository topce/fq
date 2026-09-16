#!/bin/sh
# End-to-end checks for -s/--sleep: the sleep must happen even when there was
# nothing to force-quit (that was the -o -y -s bug), must not ask twice when
# the confirmation already covered it, and must never fire when the user (or
# -y) said no.
#
# The checks are hermetic: FQ_APPS_FILE feeds fq a synthetic application list,
# so no real application is ever enumerated or killed, and FQ_SLEEP_CMD points
# fq at a stub that merely records the call, so the Mac is never put to sleep.
#
# Works on any platform: the sleep command is a stub, so nothing is really
# suspended. Usage: test_sleep.sh <path-to-fq-executable>

set -u

FQ=${1:-}
if [ -z "$FQ" ] || [ ! -x "$FQ" ]; then
  echo "usage: $0 <path-to-fq-executable>" >&2
  exit 2
fi

tmp=$(mktemp -d 2>/dev/null || echo /tmp/fq-test-sleep.$$)
mkdir -p "$tmp"
log=$tmp/sleep.log
stub=$tmp/fake-pmset
apps=$tmp/apps.txt

cat > "$stub" <<'STUB'
#!/bin/sh
printf 'SLEPT\n' >> "$FQ_STUB_LOG"
STUB
chmod +x "$stub"

# Synthetic application list. The pids are deliberately absurd (no such
# processes exist) and the only real-looking entries are the protected ones,
# which fq refuses to quit without -f. With -o, "Other App" is the sole
# victim; with --pid, no fixture pid is ever a live process.
cat > "$apps" <<'APPS'
# pid  name
600    WindowManager
624    Finder
424242 Other App
APPS

export FQ_APPS_FILE="$apps"
export FQ_SLEEP_CMD="$stub"
export FQ_STUB_LOG="$log"

failures=0
checks=0

# run <description> <stdin> <expected-sleep-count> <expected-exit> <args...>
run() {
  desc=$1
  input=$2
  want=$3
  want_status=$4
  shift 4
  checks=$((checks + 1))
  rm -f "$log"
  out=$(printf '%s' "$input" | "$FQ" "$@" 2>&1)
  status=$?
  got=0
  [ -f "$log" ] && got=$(wc -l < "$log" | tr -d ' ')
  if [ "$got" != "$want" ] || [ "$status" != "$want_status" ]; then
    failures=$((failures + 1))
    printf 'FAIL %s\n' "$desc"
    printf '     args: %s\n' "$*"
    printf '     expected %s sleep call(s) and exit %s, got %s and exit %s\n' \
      "$want" "$want_status" "$got" "$status"
    printf '     output:\n%s\n' "$out" | sed 's/^/     | /'
    return
  fi
  printf 'ok   %s\n' "$desc"
}

# The command that did nothing at all before the fix: --others with no other
# application to quit used to exit before ever reaching the sleep.
run "others, nothing to quit (-y): sleeps"        ''  1 0 -o -y -s
run "all, only protected apps (-y): sleeps"       ''  1 0 --all -y -s
run "others, nothing to quit, confirmed"          'y' 1 0 -o -s
run "others, nothing to quit, declined"           'n' 0 0 -o -s
run "others, nothing to quit, cancelled (EOF)"    ''  0 0 -o -s
run "-s alone prompts; EOF cancels, no sleep"     ''  0 0 -s
run "others, nothing to quit, no -s: no sleep"    ''  0 0 -o -y

# A victim is present: the sleep is part of the one confirmation, so a single
# 'y' must both quit and sleep — never a second prompt.
run "others with a victim (-y): quits and sleeps" ''  1 0 -o -y -s
run "others with a victim, confirmed once"        'y' 1 0 -o -s
run "others with a victim, declined: no sleep"    'n' 0 0 -o -s
run "others with a victim, no -s: no sleep"       ''  0 0 -o -y

# Name mode targets: the one combined confirmation already covers the sleep,
# so a single 'y' must both quit and sleep — this path used to ask a second
# time, and a lone 'y' then hit EOF at that second prompt and never slept.
run "name (-y): quits and sleeps"                 ''  1 0 "Other App" -y -s
run "name confirmed once: sleeps, no 2nd prompt" 'y' 1 0 "Other App" -s
run "name declined once: no sleep"               'n' 0 0 "Other App" -s
run "name, no -s: no sleep"                       ''  0 0 "Other App" -y

# --pid targets are always "real" to fq, so they exercise the same paths.
run "pid (-y): sleeps"                            ''  1 0 --pid 424242 -y -s
run "pid confirmed once: sleeps, no 2nd prompt"   'y' 1 0 --pid 424242 -s
run "pid declined once: no sleep"                 'n' 0 0 --pid 424242 -s

# Protected applications are still refused without -f, and the refusal must
# not reach the sleep.
run "protected name refused without -f"           'y' 0 1 Finder -s -y
run "protected pid refused without -f"            'y' 0 1 --pid 624 -s -y

# The interactive picker is not reached when an action is given, but a bare
# invocation with -s must not sleep when the picker is cancelled at EOF.
run "picker cancelled: no sleep"                  ''  0 0 -s

# A machine with no GUI applications at all: nothing to quit, but -s was
# asked for, so the sleep is offered on its own (never silently skipped).
apps_empty=$tmp/apps-empty.txt
printf '# no applications\n' > "$apps_empty"
FQ_APPS_FILE="$apps_empty"
run "no apps at all, confirmed (-s): sleeps"      'y' 1 0 -s
run "no apps at all, declined (-s): no sleep"     'n' 0 0 -s
run "no apps at all, cancelled (EOF): no sleep"   ''  0 0 -s
run "no apps at all, no -s: no sleep"             ''  0 0 -y
FQ_APPS_FILE="$apps"

# The "self process" regression: when fq shares a process group with an
# application that shows up in the list, --others must not force-quit it —
# SIGKILL to that group would kill fq itself before it could sleep — and -s
# must still put the machine to sleep. The group is built with python3
# (os.setpgid)
# because a process group cannot be created from POSIX sh alone; if python3 is
# unavailable this check is skipped.
if command -v python3 >/dev/null 2>&1; then
  pg_helper=$tmp/pg-self.py
  apps_group=$tmp/apps-group.txt
  cat > "$pg_helper" <<'PY'
import os, sys, time

fq = sys.argv[1]
apps_file = os.environ["FQ_APPS_FILE"]

# A process-group leader that is deliberately NOT an ancestor of fq.
leader = os.fork()
if leader == 0:
    os.setpgid(0, 0)
    time.sleep(30)
    os._exit(0)

time.sleep(0.3)
with open(apps_file, "w") as f:
    f.write("%d    Group Leader App\n" % leader)

# Run fq inside that group: killing the group would kill fq as well.
child = os.fork()
if child == 0:
    os.setpgid(0, leader)
    os.execv(fq, [fq, "-o", "-y", "-s"])
    os._exit(127)

_, status = os.waitpid(child, 0)
killed = os.WIFSIGNALED(status) and os.WTERMSIG(status) == 9
leader_alive = True
try:
    os.kill(leader, 0)
except OSError:
    leader_alive = False
try:
    os.kill(leader, 9)
except OSError:
    pass
try:
    os.waitpid(leader, 0)
except OSError:
    pass

if not leader_alive:
    sys.stderr.write("group leader was force-quit\n")
if killed:
    sys.stderr.write("fq was killed by SIGKILL\n")
sys.exit(0 if (leader_alive and not killed) else 1)
PY
  checks=$((checks + 1))
  rm -f "$log"
  FQ_APPS_FILE="$apps_group" python3 "$pg_helper" "$FQ" >/dev/null 2>&1
  pg_status=$?
  got=0
  [ -f "$log" ] && got=$(wc -l < "$log" | tr -d ' ')
  if [ "$pg_status" = "0" ] && [ "$got" = "1" ]; then
    printf 'ok   self process group (--others -y -s): kept alive, slept\n'
  else
    failures=$((failures + 1))
    printf 'FAIL self process group: helper exit %s, %s sleep call(s)\n' \
      "$pg_status" "$got"
  fi
fi

# --list cannot be combined with --sleep.
checks=$((checks + 1))
rm -f "$log"
out=$(printf '' | "$FQ" --list --sleep 2>&1)
status=$?
if [ "$status" = "2" ] && [ ! -f "$log" ]; then
  printf 'ok   --list --sleep is a usage error, no sleep\n'
else
  failures=$((failures + 1))
  printf 'FAIL --list --sleep: expected exit 2 and no sleep, got exit %s\n' "$status"
fi

rm -rf "$tmp"

if [ "$failures" -gt 0 ]; then
  printf '%s/%s sleep checks failed\n' "$failures" "$checks"
  exit 1
fi
printf 'all %s sleep checks passed\n' "$checks"
