(* fq — force-quit running macOS GUI applications.

   Behaviour mirrors the system "Force Quit" dialog (⌥⌘⎋): applications with a
   GUI are enumerated, and the chosen one is terminated immediately with
   SIGKILL. When the application leads its own process group (the normal case
   for apps launched by LaunchServices) the whole group is killed so that
   helper processes of multi-process applications (browsers, …) die too. *)

let version = "0.2.0"

type app = {
  name : string;           (* display name, e.g. "Safari" *)
  pid : int;               (* pid of the application's main process *)
  bundle : string option;  (* absolute path of the .app bundle, when known *)
}

let pp_app fmt a =
  Format.fprintf fmt "%s (pid %d)" a.name a.pid;
  match a.bundle with
  | Some b -> Format.fprintf fmt " — %s" b
  | None -> ()

type backend = Lsappinfo | Osascript

let all_backends = [ Lsappinfo; Osascript ]

let backend_to_string = function
  | Lsappinfo -> "lsappinfo"
  | Osascript -> "osascript"

let backend_of_string = function
  | "lsappinfo" -> Some Lsappinfo
  | "osascript" -> Some Osascript
  | _ -> None

(* ------------------------------------------------------------------ *)
(* Subprocess helper                                                  *)
(* ------------------------------------------------------------------ *)

let run_capture argv =
  let prog = Array.get argv 0 in
  try
    let out_r, out_w = Unix.pipe () in
    Unix.set_close_on_exec out_r;
    Unix.set_close_on_exec out_w;
    let pid = Unix.create_process prog argv Unix.stdin out_w Unix.stderr in
    Unix.close out_w;
    let ic = Unix.in_channel_of_descr out_r in
    let buf = Buffer.create 4096 in
    (try while true do Buffer.add_channel buf ic 4096 done with End_of_file -> ());
    Unix.close out_r;
    let _, status = Unix.waitpid [] pid in
    (match status with
     | Unix.WEXITED 0 -> Ok (Buffer.contents buf)
     | Unix.WEXITED n -> Error (Printf.sprintf "%s exited with status %d" prog n)
     | Unix.WSIGNALED n -> Error (Printf.sprintf "%s was killed by signal %d" prog n)
     | Unix.WSTOPPED n -> Error (Printf.sprintf "%s was stopped by signal %d" prog n))
  with
  | Unix.Unix_error (e, fn, arg) ->
    let why = Unix.error_message e in
    Error
      (Printf.sprintf "%s: %s%s" fn why
         (if arg = "" then "" else Printf.sprintf " (%s)" arg))

(* ------------------------------------------------------------------ *)
(* Parsing lsappinfo(1) output                                        *)
(* ------------------------------------------------------------------ *)

let find_sub s sub =
  let ls = String.length s and lb = String.length sub in
  if lb = 0 || lb > ls then None
  else begin
    let rec go i =
      if i + lb > ls then None
      else if String.sub s i lb = sub then Some i
      else go (i + 1)
    in
    go 0
  end

(* First double-quoted string in [s] at/after [start]; backslash escapes are
   honoured. Returns (contents, index just past the closing quote). *)
let read_quoted ?(start = 0) s =
  match String.index_from_opt s start '"' with
  | None -> None
  | Some oi ->
    let len = String.length s in
    let i = ref (oi + 1) in
    let buf = Buffer.create 32 in
    let closed = ref false in
    while (not !closed) && !i < len do
      let c = s.[!i] in
      if c = '"' then closed := true
      else if c = '\\' && !i + 1 < len then (
        (match s.[!i + 1] with
         | 'n' -> Buffer.add_char buf '\n'
         | 't' -> Buffer.add_char buf '\t'
         | 'r' -> Buffer.add_char buf '\r'
         | d -> Buffer.add_char buf d);
        i := !i + 2)
      else begin
        Buffer.add_char buf c;
        incr i
      end
    done;
    if !closed then Some (Buffer.contents buf, !i + 1) else None

(* Integer parsed from the digits starting at [i]. *)
let digits_at s i =
  let len = String.length s in
  let j = ref i in
  while !j < len && s.[!j] >= '0' && s.[!j] <= '9' do
    incr j
  done;
  if !j > i then Some (int_of_string (String.sub s i (!j - i))) else None

let skip_spaces s i =
  let len = String.length s in
  let j = ref i in
  while !j < len && s.[!j] = ' ' do
    incr j
  done;
  !j

(* The value of the first quoted string that appears after [marker]. *)
let quoted_after s marker =
  match find_sub s marker with
  | None -> None
  | Some i ->
    Option.map fst (read_quoted ~start:(skip_spaces s (i + String.length marker)) s)

let contains_sub s sub = Option.is_some (find_sub s sub)

(* Lines that begin an lsappinfo entry: optional whitespace, an index, ')'. *)
let is_entry_header line =
  let l = String.trim line in
  let n = String.length l in
  let i = ref 0 in
  while !i < n && l.[!i] >= '0' && l.[!i] <= '9' do
    incr i
  done;
  !i > 0 && !i < n && l.[!i] = ')'

(* Keep only regular GUI applications (type="Foreground"), i.e. the apps the
   Force Quit dialog shows. Agents ("UIElement") and background processes
   ("BackgroundOnly") are dropped, as are loginwindow and friends. *)
let parse_lsappinfo out =
  let blocks = ref [] in
  let cur = ref [] in
  let flush () =
    if !cur <> [] then begin
      blocks := List.rev !cur :: !blocks;
      cur := []
    end
  in
  List.iter
    (fun line ->
      if is_entry_header line then begin
        flush ();
        cur := [ line ]
      end
      else if line <> "" then cur := line :: !cur)
    (String.split_on_char '\n' out);
  flush ();
  List.rev !blocks
  |> List.filter_map (fun block ->
         let header = List.hd block in
         let text = String.concat "\n" block in
         match read_quoted header with
         | None -> None
         | Some (name, _) ->
           let pid =
             match find_sub text "pid =" with
             | Some i ->
               (match digits_at text (skip_spaces text (i + 5)) with
                | Some p -> p
                | None -> 0)
             | None -> 0
           in
           let typ =
             match quoted_after text "type=" with Some t -> t | None -> ""
           in
           if typ = "Foreground" && pid > 0 then
             Some { name; pid; bundle = quoted_after text "bundle path=" }
           else None)

(* ------------------------------------------------------------------ *)
(* Parsing the System Events listing (osascript backend)              *)
(* ------------------------------------------------------------------ *)

let parse_osascript out =
  String.split_on_char '\n' out
  |> List.filter_map (fun line ->
         if line = "" then None
         else
           match String.index_opt line '\t' with
           | None -> None
           | Some i ->
             let pid_s = String.sub line 0 i in
             let name =
               String.sub line (i + 1) (String.length line - i - 1)
             in
             (match int_of_string_opt pid_s with
              | Some pid when pid > 0 -> Some { name; pid; bundle = None }
              | _ -> None))

(* ------------------------------------------------------------------ *)
(* Enumerating running applications                                   *)
(* ------------------------------------------------------------------ *)

let sort_apps apps =
  List.sort
    (fun a b ->
      match
        String.compare
          (String.lowercase_ascii a.name)
          (String.lowercase_ascii b.name)
      with
      | 0 -> Int.compare a.pid b.pid
      | c -> c)
    apps

let osascript_script =
  String.concat "\n"
    [
      "tell application \"System Events\"";
      "  set o to \"\"";
      "  repeat with p in (every application process whose background only is false)";
      "    set o to o & (unix id of p as text) & \"\\t\" & (name of p) & \"\\n\"";
      "  end repeat";
      "  return o";
      "end tell";
    ]

let list_apps = function
  | Lsappinfo ->
    (match run_capture [| "lsappinfo"; "list" |] with
     | Ok out -> Ok (sort_apps (parse_lsappinfo out))
     | Error e -> Error e)
  | Osascript ->
    (match run_capture [| "osascript"; "-e"; osascript_script |] with
     | Ok out -> Ok (sort_apps (parse_osascript out))
     | Error e -> Error e)

let auto_list_apps () =
  let rec go = function
    | [] ->
      Error
        "could not enumerate running applications (both the lsappinfo and \
         osascript backends failed)"
    | b :: rest -> (
      match list_apps b with Ok apps -> Ok (b, apps) | Error _ -> go rest)
  in
  go all_backends

(* ------------------------------------------------------------------ *)
(* Name matching                                                      *)
(* ------------------------------------------------------------------ *)

let normalize_name s =
  let s = String.trim s in
  let s =
    if Filename.check_suffix s ".app" then Filename.chop_suffix s ".app"
    else s
  in
  String.lowercase_ascii s

type name_match = Unique of app | None_found | Ambiguous of app list

let match_name apps name =
  let target = normalize_name name in
  let lower a = String.lowercase_ascii a.name in
  let exact = List.filter (fun a -> lower a = target) apps in
  match exact with
  | [ a ] -> Unique a
  | _ :: _ -> Ambiguous exact
  | [] -> (
    (* no exact match: accept an unambiguous substring match *)
    let subs =
      List.filter (fun a -> contains_sub (lower a) target) apps
    in
    match subs with
    | [ a ] -> Unique a
    | _ :: _ -> Ambiguous subs
    | [] -> None_found)

let find_pid apps pid = List.find_opt (fun a -> a.pid = pid) apps

(* ------------------------------------------------------------------ *)
(* Comma-separated number lists (interactive multi-selection)         *)
(* ------------------------------------------------------------------ *)

(* Parse a comma-separated list of positive integers — the 1-based indexes
   printed next to the applications in the interactive picker. Optional
   whitespace around each number is allowed ("1, 3, 5"). Returns None for
   empty input, empty tokens, or any token that is not a positive integer,
   so a typo invalidates the whole input rather than half-quitting a
   selection. *)
let parse_index_list s =
  if String.trim s = "" then None
  else
    let tokens = String.split_on_char ',' s in
    let nums =
      List.map
        (fun t ->
          match int_of_string_opt (String.trim t) with
          | Some k when k > 0 -> Some k
          | _ -> None)
        tokens
    in
    if List.exists (fun x -> x = None) nums then None
    else Some (List.map Option.get nums)

(* ------------------------------------------------------------------ *)
(* Force quitting                                                     *)
(* ------------------------------------------------------------------ *)

type quit_outcome = Terminated | Already_gone

(* Process group id of another process, via ps(1). Returns None when the
   process is already gone or when ps fails. *)
let pgid_of pid =
  match run_capture [| "ps"; "-o"; "pgid="; "-p"; string_of_int pid |] with
  | Ok s -> (
    try
      let t = String.trim s in
      if t = "" then None else Some (int_of_string t)
    with Failure _ -> None)
  | Error _ -> None

(* Parent pid of another process, via ps(1). Returns None when the process
   is already gone or when ps fails. *) 
let parent_pid_of pid =
  match run_capture [| "ps"; "-o"; "ppid="; "-p"; string_of_int pid |] with
  | Ok s -> (
    try
      let t = String.trim s in
      if t = "" then None else Some (int_of_string t)
    with Failure _ -> None)
  | Error _ -> None

(* Pids of every ancestor of [pid], nearest first, stopping before launchd
   (pid 1). Used to recognise "this terminal": the GUI application hosting
   the process that ran fq is the first ancestor that shows up in the
   application list. Cycle-safe (pid reuse can loop a ppid chain in theory)
   and depth-capped. *)
let ancestor_pids ~pid =
  let rec go pid acc depth =
    if depth <= 0 then List.rev acc
    else
      match parent_pid_of pid with
      | Some pp when pp > 1 && not (List.mem pp acc) -> go pp (pp :: acc) (depth - 1)
      | _ -> List.rev acc
  in
  go pid [] 64

type kill_result = Kill_ok | Kill_gone | Kill_perm | Kill_error

let attempt_kill target =
  try
    Unix.kill target Sys.sigkill;
    Kill_ok
  with
  | Unix.Unix_error (e, _, _) ->
    if e = Unix.ESRCH then Kill_gone
    else if e = Unix.EPERM then Kill_perm
    else Kill_error

let force_quit_pid pid =
  (* When the process leads its own group, SIGKILL the whole group first so
     that helper processes die too; fall back to the single process. *)
  let targets =
    match pgid_of pid with
    | Some pg when pg = pid -> [ -pg; pid ]
    | _ -> [ pid ]
  in
  let rec go = function
    | [] ->
      Error
        "could not terminate the process (permission denied — try again with \
         sudo — or it has already exited)"
    | target :: rest -> (
      match attempt_kill target with
      | Kill_ok -> Ok Terminated
      | Kill_gone -> Ok Already_gone
      | Kill_perm | Kill_error -> go rest)
  in
  go targets

let force_quit a = force_quit_pid a.pid
