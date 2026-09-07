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
of the application to force quit it. With APP, the application whose display
name matches APP is force-quit (matching is case-insensitive and a trailing
".app" is ignored).

Options:
  -l, --list             list running applications as "pid name" and exit
  -a, --all              force quit every running application except the
                         protected system ones listed below
  -o, --others           force quit every running application except the
                         application running this terminal (fq itself) and
                         the protected system ones listed below
  -p, --pid PID          force quit the process with this PID
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

Examples:
  fq                       pick an application interactively
  fq "Safari"              force quit Safari
  fq -y firefox            non-interactive force quit
  fq --list | grep -i notes
  fq --all                 force quit every application (protected ones are
                           skipped unless -f is also given)
  fq --others              force quit every other application; this terminal
                           and the protected ones keep running
  fq --others -f           same, but also quit the protected system ones

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

let confirm ~yes ~label =
  if yes then true
  else begin
    Printf.printf "%s%s? [y/N] " (bold "Force quit ") label;
    flush stdout;
    match (try Some (input_line stdin) with End_of_file -> None) with
    | Some ans ->
      let a = String.lowercase_ascii (String.trim ans) in
      a = "y" || a = "yes"
    | None -> false
  end

let quit_app ~yes ~force a =
  let label = describe a in
  refuse_if_protected ~force ~label (is_protected a);
  if not (confirm ~yes ~label) then begin
    say "%s" (dim "Cancelled — nothing was force-quit.");
    exit 0
  end;
  match Fq.force_quit a with
  | Ok Terminated -> say "%s" (green ("Force-quit " ^ label ^ "."))
  | Ok Already_gone -> say "%s" (dim (label ^ " is no longer running."))
  | Error e -> fatal "%s" e

(* ------------------------------------------------------------------ *)
(* Modes                                                              *)
(* ------------------------------------------------------------------ *)

let print_list apps =
  List.iter (fun a -> Printf.printf "%-7d %s\n%!" a.pid a.name) apps

let interactive ~force apps =
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
  let rec choose () =
    Printf.printf "%s: " (bold "Choose an application to force quit (number), or Return to cancel");
    flush stdout;
    match (try Some (String.trim (input_line stdin)) with End_of_file -> None) with
    | None | Some "" -> exit 0
    | Some s -> (
      match int_of_string_opt s with
      | Some k when k >= 1 && k <= List.length apps -> List.nth apps (k - 1)
      | _ ->
        warn "invalid choice %S — enter a number from the list" s;
        choose ())
  in
  let a = choose () in
  quit_app ~yes:false ~force a

let name_mode ~yes ~force ~apps name =
  match Fq.match_name apps name with
  | Unique a -> quit_app ~yes ~force a
  | None_found ->
    fatal "no running application matches %S%s" name
      (if apps = [] then "" else "\nRunning applications:\n" ^ listing apps)
  | Ambiguous ms ->
    fatal "more than one running application matches %S:\n%s" name (listing ms)

let plural n s = if n = 1 then s else s ^ "s"

(* Force-quit each victim in turn, reporting per-application results.
   Exits 1 if any force-quit failed. *)
let kill_victims victims =
  let failed = ref 0 in
  List.iter
    (fun a ->
      let label = describe a in
      match Fq.force_quit a with
      | Ok Terminated -> say "%s" (green ("Force-quit " ^ label ^ "."))
      | Ok Already_gone -> say "%s" (dim (label ^ " is no longer running."))
      | Error e ->
        incr failed;
        warn "%s" e)
    victims;
  if !failed > 0 then exit 1

(* Force-quit every running application. Protected system applications are
   skipped unless --force is given. Asks for confirmation unless -y is given,
   then quits each victim and reports per-application results. *)
let all_mode ~yes ~force ~backend_opt =
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
  if not (confirm ~yes ~label:(Printf.sprintf "these %d %s" n_victims (plural n_victims "application"))) then begin
    say "%s" (dim "Cancelled — nothing was force-quit.");
    exit 0
  end;
  kill_victims victims

(* Force-quit every running application except the one running this terminal
   (an ancestor of fq itself — never killed, even with --force) and the
   protected system applications (killed only with --force). *)
let others_mode ~yes ~force ~backend_opt =
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
  if not (confirm ~yes ~label:(Printf.sprintf "these %d %s" n_victims (plural n_victims "application"))) then begin
    say "%s" (dim "Cancelled — nothing was force-quit.");
    exit 0
  end;
  kill_victims victims

let pid_mode ~yes ~force ~backend_opt pid =
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
  if not (confirm ~yes ~label) then begin
    say "%s" (dim "Cancelled — nothing was force-quit.");
    exit 0
  end;
  match Fq.force_quit_pid pid with
  | Ok Terminated -> say "%s" (green ("Force-quit " ^ label ^ "."))
  | Ok Already_gone -> say "%s" (dim (label ^ " is no longer running."))
  | Error e -> fatal "%s" e

(* ------------------------------------------------------------------ *)
(* CLI parsing                                                        *)
(* ------------------------------------------------------------------ *)

type action = List_apps | Kill_all | Kill_others | By_name of string | By_pid of int

let () =
  let n = Array.length Sys.argv in
  let idx = ref 1 in
  let yes = ref false in
  let force = ref false in
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
  ensure_darwin ();
  match !action with
  | None -> interactive ~force:!force (get_apps !backend_opt)
  | Some List_apps -> print_list (get_apps !backend_opt)
  | Some Kill_all -> all_mode ~yes:!yes ~force:!force ~backend_opt:!backend_opt
  | Some Kill_others ->
    others_mode ~yes:!yes ~force:!force ~backend_opt:!backend_opt
  | Some (By_name name) ->
    name_mode ~yes:!yes ~force:!force ~apps:(get_apps !backend_opt) name
  | Some (By_pid pid) ->
    pid_mode ~yes:!yes ~force:!force ~backend_opt:!backend_opt pid
