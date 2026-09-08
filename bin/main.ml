open Fq

let prog = "fq"
let version = Fq.version

(* ------------------------------------------------------------------ *)
(* Colours — only when stdout is a terminal.                          *)
(* ------------------------------------------------------------------ *)

let colour =
  (try Unix.isatty Unix.stdout with _ -> false)
  && Sys.getenv_opt "NO_COLOR" = None
  && Sys.getenv_opt "TERM" <> Some "dumb"

let ansi code s = if colour then "\027[" ^ code ^ "m" ^ s ^ "\027[0m" else s
let bold = ansi "1"
let red = ansi "31"
let green = ansi "32"
let yellow = ansi "33"
let dim = ansi "2"

(* ------------------------------------------------------------------ *)
(* Message helpers                                                    *)
(* ------------------------------------------------------------------ *)

let say fmt = Printf.ksprintf (fun s -> Printf.printf "%s\n%!" s) fmt
let warn fmt = Printf.ksprintf (fun s -> Printf.eprintf "%s%s\n%!" (yellow (prog ^ ": ")) s) fmt

let fatal fmt =
  Printf.ksprintf
    (fun s ->
      Printf.eprintf "%s%s\n%!" (red (prog ^ ": ")) s;
      exit 1)
    fmt

let usage_error fmt =
  Printf.ksprintf
    (fun s ->
      Printf.eprintf "%s%s\n%!" (red (prog ^ ": ")) s;
      Printf.eprintf "Try '%s --help' for more information.\n%!" prog;
      exit 2)
    fmt

(* ------------------------------------------------------------------ *)
(* Interactive prompting (Return submits; Escape cancels)             *)
(* ------------------------------------------------------------------ *)

(* Is stdin a terminal? When fq's stdin is redirected (piped scripts, tests)
   the prompts read whole lines instead of single keys, so scripting works
   exactly as before. *)
let stdin_is_tty () = try Unix.isatty Unix.stdin with _ -> false

(* Restores the terminal after single-key prompting. Kept in a ref so an
   untimely exit (^C …) still resets the tty through the at_exit hook.
   [raw_active] tells us whether we currently own the raw mode. *)
let raw_active = ref false
let tty_restore : (unit -> unit) ref = ref (fun () -> ())

let () = at_exit (fun () -> if !raw_active then !tty_restore ())

(* Leave single-key mode (idempotent). *)
let end_raw () =
  if !raw_active then begin
    raw_active := false;
    let restore = !tty_restore in
    tty_restore := (fun () -> ());
    restore ()
  end

(* Read keys one at a time while the terminal is in single-key mode: Return
   submits what was typed, Escape / ^D / ^C / EOF cancel. Echo is off, so
   accepted printable keys are echoed by hand and Backspace edits the line. *)
let read_keys prompt =
  Printf.printf "%s" (bold prompt);
  flush stdout;
  let buf = Buffer.create 16 in
  let newline () =
    print_string "\n";
    flush stdout
  in
  let rec loop () =
    match (try Some (input_char stdin) with End_of_file -> None) with
    | None ->
      newline ();
      `Cancel
    | Some '\003' ->
      newline ();
      exit 130 (* ^C *)
    | Some ('\x1b' | '\x04') -> (* Escape, ^D *)
      newline ();
      `Cancel
    | Some ('\n' | '\r') -> (* Return *)
      newline ();
      `Submit (Buffer.contents buf)
    | Some ('\b' | '\x7f') -> (* Backspace / Delete *)
      if Buffer.length buf > 0 then begin
        Buffer.truncate buf (Buffer.length buf - 1);
        print_string "\b \b";
        flush stdout
      end;
      loop ()
    | Some c when Char.code c >= 32 ->
      Buffer.add_char buf c;
      print_char c;
      flush stdout;
      loop ()
    | Some _ -> loop () (* other control keys: ignore *)
  in
  loop ()

(* Read a whole line (used when stdin is redirected): Return submits the
   trimmed line; EOF or a leading Escape cancels. *)
let read_line prompt =
  Printf.printf "%s" (bold prompt);
  flush stdout;
  match (try Some (input_line stdin) with End_of_file -> None) with
  | None -> `Cancel
  | Some s ->
    let s = String.trim s in
    if s <> "" && s.[0] = '\x1b' then `Cancel else `Submit s

(* Prompt the user. On a real terminal the tty is switched to single-key mode
   for the duration, so Escape cancels immediately, without pressing Return
   afterwards. Prompts return [`Submit s] with what was typed, or [`Cancel]
   when the user bailed out (Escape, ^D, EOF). If the terminal cannot be put
   into single-key mode we fall back to plain line input. *)
let ask prompt =
  if not (stdin_is_tty ()) then read_line prompt
  else begin
    try
      let fd = Unix.stdin in
      let saved = Unix.tcgetattr fd in
      let raw =
        { saved with
          Unix.c_icanon = false; (* deliver keys without waiting for Return *)
          c_echo = false; (* echo accepted keys by hand *)
          c_isig = false; (* ^C arrives as a key we can handle safely *)
          c_ixon = false; (* ^S/^Q must not freeze the prompt *)
          c_vmin = 1; (* reads return as soon as a key is pressed *)
          c_vtime = 0
        }
      in
      Unix.tcsetattr fd Unix.TCSANOW raw;
      raw_active := true;
      tty_restore := (fun () -> try Unix.tcsetattr fd Unix.TCSANOW saved with _ -> ());
      let out = read_keys prompt in
      end_raw ();
      out
    with
    | Unix.Unix_error _ -> read_line prompt
    | e ->
      end_raw ();
      raise e
  end

(* ------------------------------------------------------------------ *)
(* Help                                                               *)
(* ------------------------------------------------------------------ *)

let print_help () =
  Printf.printf
    "%s\n%!"
    {|Usage: fq [OPTIONS] [APP]

Force-quit running applications from the command line. Behaviour mirrors the
system "Force Quit" dialog (⌥⌘⎋): running GUI applications are listed, and the
chosen one is terminated immediately with SIGKILL — it gets no chance to save
its work. Multi-process applications (browsers, …) are taken down completely.

With no APP, fq lists the running applications interactively: type the number
of an application to force quit it, or several comma-separated numbers (e.g.
1,3,5) to force quit several at once. Press Return to submit a choice, or
Escape to cancel the picker. With APP, the application whose display name
matches APP is force-quit (matching is case-insensitive and a trailing
".app" is ignored).

Options:
  -l, --list             list running applications as "pid name" and exit
  -a, --all              force quit every running application except the
                         protected system ones listed below
  -o, --others           force quit every running application except the
                         application running this terminal (fq itself) and
                         the protected system ones listed below
  -p, --pid PID          force quit the process with this PID
  -s, --sleep            after force-quitting, also put the Mac to sleep
                         (pmset sleepnow)
  -y, --yes              force quit without asking for confirmation
  -f, --force            allow force-quitting a protected system application
                         (Finder, loginwindow, WindowManager, Dock, ...)
  -b, --backend BACKEND  enumeration backend: lsappinfo (default) | osascript
  -h, --help             show this help and exit
  -V, --version          show version and exit

Applications are enumerated with lsappinfo(1) when possible, so no
Automation/Accessibility permission is required; osascript/System Events is
used as a fallback.

Protected applications: fq refuses to force-quit core system processes
(Finder, loginwindow, WindowManager, Dock, SystemUIServer, Control Center,
Notification Center) unless -f is given. Finder appears in the list but is
marked "(protected)" and cannot be picked without -f.

The application running this terminal (the GUI app that launched the session
fq is running in) is never force-quit, even with -f: killing it would take
down fq's own terminal.

With -s/--sleep the Mac is put to sleep once the force-quits are done, so a
confirming answer also asks for the sleep ("… and put the Mac to sleep?").
When the force-quit list includes the application running this terminal
(--all, or picking the terminal in the interactive list), that app is
force-quit last and the sleep is handed to a detached helper process armed
just beforehand, so the Mac still goes to sleep even if killing the terminal
takes fq down with it. If any force-quit fails, the Mac is not put to sleep
and fq exits 1.

Examples:
  fq                       pick application(s) interactively (type 1,3,5 to
                           force quit several at once)
  fq "Safari"              force quit Safari
  fq -y firefox            non-interactive force quit
  fq --list | grep -i notes
  fq --all                 force quit every application (protected ones are
                           skipped unless -f is also given)
  fq --others              force quit every other application; this terminal
                           and the protected ones keep running
  fq --others -f           same, but also quit the protected system ones
  fq -s "Safari"           force quit Safari, then put the Mac to sleep
  fq --all -y -s           force quit everything, then put the Mac to sleep
                           (this terminal is force-quit too; the sleep still
                           happens)

Exit status:
  0  everything requested was force-quit or already gone; nothing was done
  1  error (application not found, permission denied, ...)
  2  usage error|}

(* ------------------------------------------------------------------ *)
(* Plumbing                                                           *)
(* ------------------------------------------------------------------ *)

let ensure_darwin () =
  match run_capture [| "uname"; "-s" |] with
  | Ok s when String.trim s = "Darwin" -> ()
  | _ -> fatal "this tool requires macOS (the Force Quit dialog is a macOS feature)"

let fetch_apps backend_opt =
  match backend_opt with
  | Some b -> Fq.list_apps b
  | None -> Result.map snd (Fq.auto_list_apps ())

let get_apps backend_opt =
  match fetch_apps backend_opt with
  | Ok l -> l
  | Error e -> fatal "%s" e

let describe a = Printf.sprintf "%S (pid %d)" a.name a.pid

let listing apps =
  String.concat "\n" (List.map (fun a -> Printf.sprintf "  %s" (describe a)) apps)

(* ------------------------------------------------------------------ *)
(* Protected system applications                                     *)
(* ------------------------------------------------------------------ *)

(* Core system UI processes that must not be force-quit by accident. Finder
   is relaunched automatically by launchd, but killing it is jarring; the
   others (loginwindow, WindowManager, Dock, …) underpin the whole session.
   [fq] refuses to kill these unless -f/--force is given. Names are compared
   case-insensitively, ignoring spaces ("Control Center" == "controlcenter"). *)
let protected_names =
  [ "finder"; "loginwindow"; "windowmanager"; "dock"; "systemuiserver";
    "controlcenter"; "notificationcenter" ]

let norm_name s =
  String.concat "" (String.split_on_char ' ' (String.lowercase_ascii s))

let is_protected_name s = List.mem (norm_name s) protected_names
let is_protected a = is_protected_name a.name

(* Pids that "are" this invocation of fq: fq itself and every ancestor
   process. The GUI application hosting the terminal that ran fq is the
   ancestor that shows up in the application list; force-quitting it would
   take down our own session, so --others never touches it. *)
let self_pids () = Unix.getpid () :: Fq.ancestor_pids ~pid:(Unix.getpid ())

(* Executable basename of a process, for protecting --pid targets that could
   not be resolved against the enumerated application list. *)
let executable_of_pid pid =
  match Fq.run_capture [| "ps"; "-o"; "comm="; "-p"; string_of_int pid |] with
  | Ok s ->
    let p = String.trim s in
    if p = "" then None else Some (try Filename.basename p with _ -> p)
  | Error _ -> None

let refuse_if_protected ~force ~label protected =
  if (not force) && protected then
    fatal
      "%s is a protected system application and will not be force-quit.\n\
       \  Use %s to override if you really mean it."
      label (bold "-f/--force")

(* Ask “Force quit …? [y/N]”. y/yes answers yes; anything else — Return on an
   empty line, Escape, ^D or EOF — answers no. *)
let confirm ~yes ~label =
  if yes then true
  else
    match ask ("Force quit " ^ label ^ "? [y/N] ") with
    | `Cancel -> false
    | `Submit ans ->
      let a = String.lowercase_ascii (String.trim ans) in
      a = "y" || a = "yes"

let plural n s = if n = 1 then s else s ^ "s"

(* ------------------------------------------------------------------ *)
(* Sleep (-s/--sleep)                                                 *)
(* ------------------------------------------------------------------ *)

(* Put the Mac to sleep immediately; pmset(1) needs no special permission. *)
let sleep_macos () =
  match Fq.run_capture [| "pmset"; "sleepnow" |] with
  | Ok _ -> say "%s" (green "Putting the Mac to sleep.")
  | Error e -> fatal "could not put the Mac to sleep: %s" e

(* Arm a fully detached helper that waits [delay] seconds, then puts the Mac
   to sleep. Needed when the force-quit list includes the application running
   this terminal: killing that app can take fq's own process group with it,
   so fq may not live long enough to run pmset itself. The helper gets its
   own session (setsid) and /dev/null for stdio, so tearing down the
   terminal session cannot stop it either. If fq survives, it sleeps
   directly and this helper simply finds the Mac already asleep. *)
let arm_delayed_sleep ~delay =
  let cmd = Printf.sprintf "sleep %g; pmset sleepnow" delay in
  match Unix.fork () with
  | 0 -> (
    (try ignore (Unix.setsid ()) with _ -> ());
    let devnull = Unix.openfile "/dev/null" [ Unix.O_RDWR ] 0 in
    (try Unix.dup2 devnull Unix.stdin with _ -> ());
    (try Unix.dup2 devnull Unix.stdout with _ -> ());
    (try Unix.dup2 devnull Unix.stderr with _ -> ());
    (try Unix.close devnull with _ -> ());
    try Unix.execvp "sh" [| "sh"; "-c"; cmd |] with _ -> exit 127)
  | _ -> ()

(* Force-quit the victims, reporting per-application results, then — when
   ~sleep is set — put the Mac to sleep. The application running this
   terminal, if it is among the victims, is force-quit last, since killing it
   may take fq's own process group down with it; a detached helper is armed
   just before that kill so the Mac still goes to sleep afterwards. Exits 1
   if any force-quit failed — the Mac is not put to sleep then. *)
let finish_quits ~sleep victims =
  let self = self_pids () in
  let here, others = List.partition (fun a -> List.mem a.pid self) victims in
  let failed = ref 0 in
  let kill_one a =
    let label = describe a in
    match Fq.force_quit a with
    | Ok Terminated -> say "%s" (green ("Force-quit " ^ label ^ "."))
    | Ok Already_gone -> say "%s" (dim (label ^ " is no longer running."))
    | Error e ->
      incr failed;
      warn "%s" e
  in
  List.iter kill_one others;
  if here <> [] then begin
    (* The app running this terminal goes last — and the detached helper is
       armed only when nothing failed so far, so a partial failure never
       puts the Mac to sleep behind fq's back. *)
    if sleep && !failed = 0 then arm_delayed_sleep ~delay:1.0;
    List.iter kill_one here
  end;
  if !failed > 0 then begin
    if sleep then
      warn "not putting the Mac to sleep — %d %s failed" !failed
        (plural !failed "force-quit");
    exit 1
  end;
  if sleep then sleep_macos ()

(* ------------------------------------------------------------------ *)
(* Modes                                                              *)
(* ------------------------------------------------------------------ *)

let print_list apps =
  List.iter (fun a -> Printf.printf "%-7d %s\n%!" a.pid a.name) apps

let interactive ~force ~sleep apps =
  if apps = [] then begin
    say "%s" (dim "No running applications to force quit.");
    exit 0
  end;
  say "%s" (bold "Force Quit Applications");
  List.iteri
    (fun i a ->
      let mark =
        if is_protected a then " " ^ dim "(protected)" else ""
      in
      Printf.printf "  %2d. %s  %s%s\n%!" (i + 1) a.name
        (dim (Printf.sprintf "(pid %d)" a.pid)) mark)
    apps;
  (* Turn the user's input into the chosen apps: a single number or several
     comma-separated numbers ("1,3,5") referring to the numbered list above.
     Any out-of-range or non-numeric part invalidates the whole input.
     Return submits; Escape (or ^D) cancels. *)
  let rec choose () =
    match
      ask
        "Choose application(s) to force quit (comma-separated numbers, e.g. \
         1,3,5; Return submits, Escape cancels): "
    with
    | `Cancel | `Submit "" -> exit 0
    | `Submit s -> (
      let n = List.length apps in
      let indexes =
        match Fq.parse_index_list s with
        | None -> None
        | Some ks ->
          if List.exists (fun k -> k < 1 || k > n) ks then None else Some ks
      in
      match indexes with
      | None ->
        warn
          "invalid choice %S — enter number(s) from the list, comma-separated \
           (e.g. 1,3,5)"
          s;
        choose ()
      | Some ks ->
        (* Numbered indexes -> apps, dropping repeated indexes. *)
        let rec nodup acc = function
          | [] -> List.rev acc
          | k :: rest ->
            if List.mem k acc then nodup acc rest
            else nodup (k :: acc) rest
        in
        List.map (fun k -> List.nth apps (k - 1)) (nodup [] ks))
  in
  let victims = choose () in
  (* Refuse protected system applications unless --force is given, exactly
     like picking one by itself. *)
  (match List.filter is_protected victims with
   | [] -> ()
   | prot ->
     let verb =
       if List.length prot = 1 then "is a protected system application"
       else "are protected system applications"
     in
     fatal
       "%s %s and will not be force-quit.\n  Use %s to override if you really mean it."
       (String.concat ", " (List.map describe prot)) verb
       (bold "-f/--force"));
  let n_victims = List.length victims in
  let names =
    String.concat ", "
      (List.map (fun a -> Printf.sprintf "%s (pid %d)" a.name a.pid) victims)
  in
  let label =
    if n_victims = 1 then names
    else
      Printf.sprintf "these %d %s (%s)" n_victims
        (plural n_victims "application") names
  in
  let label = if sleep then label ^ " and put the Mac to sleep" else label in
  if not (confirm ~yes:false ~label) then begin
    say "%s" (dim "Cancelled — nothing was force-quit.");
    exit 0
  end;
  finish_quits ~sleep victims

let name_mode ~yes ~force ~sleep ~apps name =
  match Fq.match_name apps name with
  | Unique a ->
    let label = describe a in
    refuse_if_protected ~force ~label (is_protected a);
    let label = if sleep then label ^ " and put the Mac to sleep" else label in
    if not (confirm ~yes ~label) then begin
      say "%s" (dim "Cancelled — nothing was force-quit.");
      exit 0
    end;
    finish_quits ~sleep [ a ]
  | None_found ->
    fatal "no running application matches %S%s" name
      (if apps = [] then "" else "\nRunning applications:\n" ^ listing apps)
  | Ambiguous ms ->
    fatal "more than one running application matches %S:\n%s" name (listing ms)

(* Force-quit every running application. Protected system applications are
   skipped unless --force is given. Asks for confirmation unless -y is given,
   then quits each victim and reports per-application results. *)
let all_mode ~yes ~force ~sleep ~backend_opt =
  let apps = get_apps backend_opt in
  let victims, skipped =
    if force then (apps, [])
    else List.partition (fun a -> not (is_protected a)) apps
  in
  let n_victims = List.length victims in
  let n_skipped = List.length skipped in
  if n_victims = 0 then begin
    if n_skipped > 0 then
      say "%s"
        (dim
           (Printf.sprintf
              "No force-quittable applications (skipped %d protected; use %s to include them)"
              n_skipped (bold "-f/--force")))
    else say "%s" (dim "No running applications to force quit.");
    exit 0
  end;
  say "%s" (bold "Force Quit Applications");
  List.iteri
    (fun i a ->
      Printf.printf "  %2d. %s  %s\n%!" (i + 1) a.name
        (dim (Printf.sprintf "(pid %d)" a.pid)))
    victims;
  if n_skipped > 0 then
    say "%s"
      (dim
         (Printf.sprintf "(%d protected %s skipped — use %s to include them)"
            n_skipped (plural n_skipped "application") (bold "-f/--force")));
  let confirm_label =
    Printf.sprintf "these %d %s" n_victims (plural n_victims "application")
    ^ if sleep then " and put the Mac to sleep" else ""
  in
  if not (confirm ~yes ~label:confirm_label) then begin
    say "%s" (dim "Cancelled — nothing was force-quit.");
    exit 0
  end;
  finish_quits ~sleep victims

(* Force-quit every running application except the one running this terminal
   (an ancestor of fq itself — never killed, even with --force) and the
   protected system applications (killed only with --force). *)
let others_mode ~yes ~force ~sleep ~backend_opt =
  let apps = get_apps backend_opt in
  let is_self a = List.mem a.pid (self_pids ()) in
  let here, rest = List.partition is_self apps in
  let victims, skipped =
    if force then (rest, [])
    else List.partition (fun a -> not (is_protected a)) rest
  in
  let n_victims = List.length victims in
  let n_skipped = List.length skipped in
  if n_victims = 0 then begin
    let notes = ref [] in
    if here <> [] then
      notes :=
        Printf.sprintf "%d %s running this terminal — never force-quit"
          (List.length here) (plural (List.length here) "application")
        :: !notes;
    if n_skipped > 0 then
      notes :=
        Printf.sprintf "%d protected %s — use %s to include them" n_skipped
          (plural n_skipped "application") (bold "-f/--force")
        :: !notes;
    if !notes <> [] then
      say "%s" (dim ("No force-quittable other applications (" ^ String.concat "; " (List.rev !notes) ^ ")."))
    else say "%s" (dim "No running applications to force quit.");
    exit 0
  end;
  say "%s" (bold "Force Quit Other Applications");
  List.iteri
    (fun i a ->
      Printf.printf "  %2d. %s  %s\n%!" (i + 1) a.name
        (dim (Printf.sprintf "(pid %d)" a.pid)))
    victims;
  if n_skipped > 0 then
    say "%s"
      (dim
         (Printf.sprintf "(%d protected %s skipped — use %s to include them)"
            n_skipped (plural n_skipped "application") (bold "-f/--force")));
  if here <> [] then
    say "%s"
      (dim
         (Printf.sprintf
            "(kept running: %s — the application running this terminal is never force-quit)"
            (String.concat ", "
               (List.map (fun a -> Printf.sprintf "%s (pid %d)" a.name a.pid) here))));
  let confirm_label =
    Printf.sprintf "these %d %s" n_victims (plural n_victims "application")
    ^ if sleep then " and put the Mac to sleep" else ""
  in
  if not (confirm ~yes ~label:confirm_label) then begin
    say "%s" (dim "Cancelled — nothing was force-quit.");
    exit 0
  end;
  finish_quits ~sleep victims

let pid_mode ~yes ~force ~sleep ~backend_opt pid =
  let known =
    match fetch_apps backend_opt with
    | Ok l -> Fq.find_pid l pid
    | Error _ -> None
  in
  let label =
    match known with
    | Some a -> describe a
    | None -> Printf.sprintf "process %d" pid
  in
  let protected =
    match known with
    | Some a -> is_protected a
    | None -> (
      match executable_of_pid pid with
      | Some b -> is_protected_name b
      | None -> false)
  in
  refuse_if_protected ~force ~label protected;
  let confirm_label =
    if sleep then label ^ " and put the Mac to sleep" else label
  in
  if not (confirm ~yes ~label:confirm_label) then begin
    say "%s" (dim "Cancelled — nothing was force-quit.");
    exit 0
  end;
  (* The Mac is put to sleep after the kill. If the target is the application
     running this terminal, arm the detached helper first — killing that app
     can take fq's own process group with it, and the helper then still puts
     the Mac to sleep a moment later. *)
  if sleep && List.mem pid (self_pids ()) then arm_delayed_sleep ~delay:1.0;
  (match Fq.force_quit_pid pid with
   | Ok Terminated -> say "%s" (green ("Force-quit " ^ label ^ "."))
   | Ok Already_gone -> say "%s" (dim (label ^ " is no longer running."))
   | Error e -> fatal "%s" e);
  if sleep then sleep_macos ()

(* ------------------------------------------------------------------ *)
(* CLI parsing                                                        *)
(* ------------------------------------------------------------------ *)

type action = List_apps | Kill_all | Kill_others | By_name of string | By_pid of int

let () =
  let n = Array.length Sys.argv in
  let idx = ref 1 in
  let yes = ref false in
  let force = ref false in
  let sleep = ref false in
  let backend_opt = ref None in
  let action = ref None in
  let want_help = ref false in
  let want_version = ref false in
  let set_action a =
    match !action with
    | None -> action := Some a
    | Some _ ->
      usage_error
        "conflicting actions (pass an application name, --pid, --list, --all, \
         or --others — not several)"
  in
  let next name =
    incr idx;
    if !idx >= n then usage_error "%s requires an argument" name;
    Sys.argv.(!idx)
  in
  while !idx < n do
    let a = Sys.argv.(!idx) in
    if a = "--" then begin
      while !idx + 1 < n do
        incr idx;
        set_action (By_name Sys.argv.(!idx))
      done
    end
    else if String.length a > 1 && a.[0] = '-' then begin
      match a with
      | "-h" | "--help" -> want_help := true
      | "-V" | "--version" -> want_version := true
      | "-y" | "--yes" -> yes := true
      | "-f" | "--force" -> force := true
      | "-s" | "--sleep" -> sleep := true
      | "-l" | "--list" -> set_action List_apps
      | "-a" | "--all" -> set_action Kill_all
      | "-o" | "--others" -> set_action Kill_others
      | "-p" | "--pid" ->
        let v = next a in
        (match int_of_string_opt v with
         | Some p when p > 0 -> set_action (By_pid p)
         | _ -> usage_error "--pid expects a positive integer, got %S" v)
      | "-b" | "--backend" ->
        let v = next a in
        (match Fq.backend_of_string v with
         | Some b -> backend_opt := Some b
         | None ->
           usage_error "unknown backend %S (expected %s)" v
             (String.concat " or " (List.map Fq.backend_to_string Fq.all_backends)))
      | _ -> usage_error "unknown option %S (try --help)" a
    end
    else set_action (By_name a);
    incr idx
  done;

  if !want_version then begin
    Printf.printf "%s %s\n%!" prog version;
    exit 0
  end;
  if !want_help then begin
    print_help ();
    exit 0
  end;
  if !sleep && !action = Some List_apps then
    usage_error "--list cannot be combined with --sleep";
  ensure_darwin ();
  match !action with
  | None -> interactive ~force:!force ~sleep:!sleep (get_apps !backend_opt)
  | Some List_apps -> print_list (get_apps !backend_opt)
  | Some Kill_all ->
    all_mode ~yes:!yes ~force:!force ~sleep:!sleep ~backend_opt:!backend_opt
  | Some Kill_others ->
    others_mode ~yes:!yes ~force:!force ~sleep:!sleep ~backend_opt:!backend_opt
  | Some (By_name name) ->
    name_mode ~yes:!yes ~force:!force ~sleep:!sleep
      ~apps:(get_apps !backend_opt) name
  | Some (By_pid pid) ->
    pid_mode ~yes:!yes ~force:!force ~sleep:!sleep ~backend_opt:!backend_opt pid
