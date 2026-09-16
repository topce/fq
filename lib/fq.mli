(** Force-quit running GUI applications — on macOS, Linux and Windows.

    The command line is the same everywhere; only the implementation differs.
    On macOS the behaviour mirrors the system "Force Quit" dialog (⌥⌘⎋):
    applications are enumerated and the chosen one is terminated immediately,
    with no chance to save work. Linux and Windows get the closest equivalent:
    the applications of the current graphical session are enumerated, and a
    victim is killed together with the helper processes that belong to it. *)

val version : string

(** Run [argv] (argv.(0) is the program) capturing its stdout; child stderr
    is inherited. Returns the captured output on success. *)
val run_capture : string array -> (string, string) result

(** Read a whole file. Used for /proc, .desktop entries and the environment
    hooks the test suite uses. *)
val read_file : string -> (string, string) result

(** A running application. *)
type app = {
  name : string;       (** Display name, e.g. ["Safari"]. *)
  pid : int;           (** PID of the application's main process. *)
  bundle : string option; (** macOS: the [.app] bundle; Linux: the [.desktop]
                              file; [None] when unknown. *)
}

val pp_app : Format.formatter -> app -> unit

(** The platform fq runs on. [FQ_PLATFORM] overrides the detection, which is
    how the test suite drives the Linux and Windows code paths anywhere. *)
type platform = Macos | Linux | Windows | Other of string

val platform : unit -> platform
val platform_name : unit -> string

(** Is the platform one fq knows how to drive (macOS, Linux, Windows)? *)
val supported_platform : unit -> bool

val is_macos : unit -> bool
val is_linux : unit -> bool
val is_windows : unit -> bool

(** ["the Mac"] / ["the computer"] / ["the PC"], for messages that read
    naturally everywhere. *)
val machine_name : unit -> string

(** ["put the Mac to sleep"] / ["put the computer to sleep"] /
    ["put the PC to sleep"]. *)
val sleep_phrase : unit -> string

(** Backends used to enumerate running applications. Only the backends of the
    current platform are accepted by {!backend_of_string}. *)
type backend =
  | Lsappinfo    (** macOS: lsappinfo(1) — needs no TCC permission. *)
  | Osascript    (** macOS: System Events via osascript. *)
  | Procfs       (** Linux: /proc scan, no external tools. *)
  | Wmctrl       (** Linux/X11: wmctrl(1) — the windows currently on screen. *)
  | Tasklist     (** Windows: tasklist(1), windowed processes only. *)
  | Powershell   (** Windows: Get-Process, windowed processes only. *)

(** Backends of the current platform, in order of preference. *)
val all_backends : unit -> backend list

val backend_to_string : backend -> string

(** [backend_of_string s] is the backend named [s], when it exists on the
    current platform. *)
val backend_of_string : string -> backend option

(** [list_apps b] lists the running GUI applications reported by backend [b],
    sorted by name. *)
val list_apps : backend -> (app list, string) result

(** [auto_list_apps ()] tries the backends of this platform in order of
    preference and returns the first that succeeds. *)
val auto_list_apps : unit -> (backend * app list, string) result

(** Result of looking an application up by name. *)
type name_match =
  | Unique of app
  | None_found
  | Ambiguous of app list

(** [match_name apps s] finds the running application whose display name
    matches [s]. Matching is case-insensitive and a trailing [".app"] is
    ignored; unambiguous substring matches are also accepted. *)
val match_name : app list -> string -> name_match

(** [find_pid apps pid] returns the application with the given pid, if any. *)
val find_pid : app list -> int -> app option

(** Parse a comma-separated list of positive integers ("1, 3, 5") — the
    1-based indexes shown next to applications in the interactive picker.
    Optional whitespace around each number is allowed. Returns [None] on
    empty input, empty tokens, or any token that is not a positive
    integer, so a typo invalidates the whole input rather than
    half-quitting a selection. *)
val parse_index_list : string -> int list option

(** Parent pid of another process; [None] when the process is gone or cannot
    be inspected. Reads /proc on Linux, PowerShell on Windows, ps(1)
    elsewhere. *)
val parent_pid_of : int -> int option

(** Pids of the ancestors of [pid], nearest first, walking the [ppid] chain
    up to but excluding init/launchd (pid 1). Cycle-safe (pid reuse) and
    depth-capped. Used to recognise the application running this terminal. *)
val ancestor_pids : pid:int -> int list

(** Pids of the descendants of [pid], nearest first. Linux only — elsewhere
    the process group is what gets killed, and this returns [[]]. *)
val descendants_of : int -> int list

(** Executable basename of a process, for protecting [--pid] targets that are
    not in the enumerated application list. *)
val executable_of_pid : int -> string option

(** Process group of this process, if it can be determined. Used to make
    sure a force-quit never signals fq's own group: doing so would kill
    fq before it could finish, e.g. before the sleep requested with
    [-s/--sleep]. [None] on Windows. *)
val own_process_group : unit -> int option

(** Outcome of a force-quit request. *)
type quit_outcome = Terminated | Already_gone

(** [force_quit app] force-quits [app], helper processes included:

    - macOS/Linux: when the application leads its own process group the whole
      group is SIGKILLed; on Linux an application that does not lead a group
      has its process tree killed instead. fq's own process and process group
      are never signalled.
    - Windows: [taskkill /T /F], which terminates the process tree. *)
val force_quit : app -> (quit_outcome, string) result

(** [force_quit_pid pid] is {!force_quit} for a bare pid. fq's own process is
    never signalled. *)
val force_quit_pid : int -> (quit_outcome, string) result

(** Names of the protected system applications of this platform: core session
    processes (Finder and the Dock on macOS, the shell and the window manager
    on Linux, Explorer and the session processes on Windows) that fq refuses
    to force-quit unless [-f/--force] is given. *)
val protected_names : unit -> string list

(** [is_protected_name s] compares case-insensitively, ignoring spaces and a
    trailing [.app]/[.exe]/[.desktop]. *)
val is_protected_name : string -> bool

val is_protected : app -> bool

(** Command that puts this machine to sleep, as an argv ([pmset sleepnow],
    [systemctl suspend], PowerShell [SetSuspendState], …). [FQ_SLEEP_CMD]
    overrides it. *)
val sleep_invocation : unit -> string array

(** The same command in short, readable form ([pmset sleepnow],
    [systemctl suspend], [SetSuspendState], or the [FQ_SLEEP_CMD] value), for
    messages and help text. *)
val sleep_command_display : unit -> string

(** Put the machine to sleep now, trying the platform's sleep commands in
    order of preference. *)
val sleep_now : unit -> (unit, string) result

(** Arm a fully detached helper that waits [delay] seconds and then puts the
    machine to sleep. Used when the force-quit list includes the application
    running this terminal, which may take fq down with it. *)
val arm_delayed_sleep : delay:float -> unit

(** {2 Parsers — exposed for testing} *)

(** Parser for [lsappinfo list] output (macOS). *)
val parse_lsappinfo : string -> app list

(** Parser for tab-separated [pid<TAB>name] output: System Events via
    osascript (macOS) and Get-Process via PowerShell (Windows). *)
val parse_osascript : string -> app list

(** Parser for [wmctrl -lpx] output (Linux/X11). Windows are deduplicated by
    pid: the application, not the window, is what fq quits. *)
val parse_wmctrl : string -> app list

(** Parser for [tasklist /V /FO CSV /NH] output (Windows). Rows without a
    window title (["N/A"]) are services and console processes and are
    dropped. *)
val parse_tasklist : string -> app list

(** One line of RFC-4180-ish CSV (quoted fields, doubled quotes). *)
val parse_csv_line : string -> string list

(** The fields of one [/proc/<pid>/stat] line that matter here. [p_tty_nr] is
    the controlling terminal (0 when there is none) and [p_tpgid] is the
    process group that terminal is running in the foreground, which is how a
    console program is told apart from an application. *)
type proc_info = {
  p_pid : int;
  p_ppid : int;
  p_pgrp : int;
  p_session : int;
  p_tty_nr : int;
  p_tpgid : int;
  p_comm : string;
}

val parse_proc_stat : string -> proc_info option

(** Does this [/proc/<pid>/environ] contents belong to a process in a
    graphical session (non-empty DISPLAY or WAYLAND_DISPLAY)? *)
val has_graphical_env : string -> bool

(** Key/value pairs of the [Desktop Entry] group of a .desktop file. *)
val parse_desktop_entry : string -> (string * string) list

(** The program an [Exec=] line runs, as a basename (["env FOO=bar gimp %U"]
    → ["gimp"]); [None] for launchers that only wrap another app. *)
val desktop_exec_basename : string -> string option

(** [list_apps_procfs ~proc_root ~desktop_dirs] enumerates desktop
    applications from a /proc-like directory tree, naming them after the
    matching .desktop entry when there is one. *)
val list_apps_procfs :
  proc_root:string -> desktop_dirs:string list -> (app list, string) result

(** Is this executable name session infrastructure (window manager,
    compositor, panel, session/sound daemon, portal, input method)? *)
val is_linux_infrastructure : string -> bool

(** Normalized form used to compare application names: lower case, no spaces,
    no [.app]/[.exe]/[.desktop] suffix. *)
val normalize_app_name : string -> string
