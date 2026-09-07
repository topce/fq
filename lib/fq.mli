(** Force-quit running macOS GUI applications, mirroring the behaviour of the
    system "Force Quit" dialog (⌥⌘⎋): applications are enumerated, and the
    chosen one is terminated immediately with SIGKILL — no chance to save work. *)

val version : string

(** Run [argv] (argv.(0) is the program) capturing its stdout; child stderr
    is inherited. Returns the captured output on success. *)
val run_capture : string array -> (string, string) result

(** A running application. *)
type app = {
  name : string;       (** Display name, e.g. ["Safari"]. *)
  pid : int;           (** PID of the application's main process. *)
  bundle : string option; (** Absolute path of the [.app] bundle, when known. *)
}

val pp_app : Format.formatter -> app -> unit

(** Backends used to enumerate running applications. *)
type backend = Lsappinfo | Osascript

val all_backends : backend list
val backend_to_string : backend -> string
val backend_of_string : string -> backend option

(** [list_apps b] lists the running GUI applications reported by backend [b],
    sorted by name. *)
val list_apps : backend -> (app list, string) result

(** [auto_list_apps ()] tries the backends in order of preference and returns
    the first that succeeds. [lsappinfo(1)] is preferred because it needs no
    Automation/Accessibility permissions. *)
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

(** Parent pid of another process, via [ps(1)]; [None] when the process is
    gone or [ps] fails. *)
val parent_pid_of : int -> int option

(** Pids of the ancestors of [pid], nearest first, walking the [ppid] chain
    up to but excluding launchd (pid 1). Cycle-safe (pid reuse) and
    depth-capped. Used to recognise the application running this terminal. *)
val ancestor_pids : pid:int -> int list

(** Outcome of a force-quit request. *)
type quit_outcome = Terminated | Already_gone

(** [force_quit app] force-quits [app] with SIGKILL. When the application
    leads its own process group — the normal case for applications launched by
    LaunchServices, verified via [ps] — the whole group is killed, so helper
    processes of multi-process applications (browsers, …) are taken down too.
    Otherwise only the main process is killed. *)
val force_quit : app -> (quit_outcome, string) result

(** [force_quit_pid pid] force-quits the process (and, when it leads its own
    process group, that group). *)
val force_quit_pid : int -> (quit_outcome, string) result

(** Parser for [lsappinfo list] output; exposed for testing. *)
val parse_lsappinfo : string -> app list

(** Parser for the System Events tab-separated [pid<TAB>name] listing; exposed
    for testing. *)
val parse_osascript : string -> app list
