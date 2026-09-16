(* fq — force-quit running GUI applications from the command line.

   The CLI is the same on every platform; only the implementation differs:

   * macOS — applications are enumerated with lsappinfo(1) (System Events via
     osascript as a fallback), exactly the applications the system "Force Quit"
     dialog (⌥⌘⎋) shows. A victim's process group is SIGKILLed, so helper
     processes of multi-process applications die with it.

   * Linux — applications are enumerated from /proc (a process counts as a
     desktop application when it runs in a graphical session and is not a
     console program), with wmctrl(1) available as an alternative backend.
     Names come from the matching .desktop entry when there is one. A victim's
     process group is SIGKILLed; a victim that does not lead its own group has
     its process tree killed instead.

   * Windows — applications are enumerated with tasklist(1) (windowed
     processes only), PowerShell as an alternative. Victims are terminated with
     taskkill /T /F, which takes the whole process tree down.

   Everything else — listing, name matching, the interactive picker, the
   protected-system-application list, --others, and -s/--sleep — behaves the
   same everywhere. *)

let version = "0.4.0"

(* ------------------------------------------------------------------ *)
(* Applications                                                       *)
(* ------------------------------------------------------------------ *)

type app = {
  name : string;           (* display name, e.g. "Safari" *)
  pid : int;               (* pid of the application's main process *)
  bundle : string option;  (* macOS: the .app bundle, when known
                              Linux: the .desktop file, when known *)
}

let pp_app fmt a =
  Format.fprintf fmt "%s (pid %d)" a.name a.pid;
  match a.bundle with
  | Some b -> Format.fprintf fmt " — %s" b
  | None -> ()

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

(* Value of an environment variable, trimmed; [None] when unset or blank. *)
let env_trim name =
  match Sys.getenv_opt name with
  | Some s when String.trim s <> "" -> Some (String.trim s)
  | _ -> None

(* ------------------------------------------------------------------ *)
(* Subprocesses and files                                             *)
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

(* Read a whole file. Used for /proc, .desktop entries, and the FQ_*_FILE test
   hooks (which must work on Windows too, where there is no cat(1)). *)
let read_file path =
  try
    let ic = open_in_bin path in
    let n = in_channel_length ic in
    let s = really_input_string ic n in
    close_in ic;
    Ok s
  with
  | Sys_error e -> Error e
  | End_of_file -> Error (Printf.sprintf "%s: unexpected end of file" path)

(* [run_capture_all argv] is [run_capture] with the child's stderr captured
   together with its stdout. Some tools say *why* they failed on stderr —
   taskkill reports a process that is already gone as "not found" there — and
   that text decides what happened, so it must not be lost. *)
let run_capture_all argv =
  let prog = Array.get argv 0 in
  try
    let out_r, out_w = Unix.pipe () in
    Unix.set_close_on_exec out_r;
    Unix.set_close_on_exec out_w;
    let pid = Unix.create_process prog argv Unix.stdin out_w out_w in
    Unix.close out_w;
    let ic = Unix.in_channel_of_descr out_r in
    let buf = Buffer.create 4096 in
    (try while true do Buffer.add_channel buf ic 4096 done with End_of_file -> ());
    Unix.close out_r;
    let _, status = Unix.waitpid [] pid in
    let out = String.trim (Buffer.contents buf) in
    let failure what =
      Error
        (if out = "" then Printf.sprintf "%s %s" prog what
         else Printf.sprintf "%s (%s)" out what)
    in
    (match status with
     | Unix.WEXITED 0 -> Ok out
     | Unix.WEXITED n -> failure (Printf.sprintf "exited with status %d" n)
     | Unix.WSIGNALED n -> failure (Printf.sprintf "was killed by signal %d" n)
     | Unix.WSTOPPED n -> failure (Printf.sprintf "was stopped by signal %d" n))
  with
  | Unix.Unix_error (e, fn, arg) ->
    let why = Unix.error_message e in
    Error
      (Printf.sprintf "%s: %s%s" fn why
         (if arg = "" then "" else Printf.sprintf " (%s)" arg))

let contains_sub s sub =
  let ls = String.length s and lb = String.length sub in
  if lb = 0 || lb > ls then false
  else begin
    let rec go i =
      if i + lb > ls then false
      else if String.sub s i lb = sub then true
      else go (i + 1)
    in
    go 0
  end

let lowercase = String.lowercase_ascii

(* ------------------------------------------------------------------ *)
(* Platform                                                           *)
(* ------------------------------------------------------------------ *)

type platform = Macos | Linux | Windows | Other of string

let detect_platform () =
  match env_trim "FQ_PLATFORM" with
  | Some v -> (
    match lowercase v with
    | "macos" | "mac" | "osx" | "darwin" -> Macos
    | "linux" -> Linux
    | "windows" | "win" | "win32" | "win64" -> Windows
    | other -> Other other)
  | None ->
    if Sys.win32 then Windows
    else (
      match run_capture [| "uname"; "-s" |] with
      | Ok s -> (
        match String.trim s with
        | "Darwin" -> Macos
        | "Linux" -> Linux
        | other -> Other other)
      | Error _ -> Other "unknown")

let platform_cache = ref None

(* The platform fq is running on. FQ_PLATFORM overrides the detection, which
   is what the test suite uses to drive the Linux and Windows code paths on a
   developer machine. *)
let platform () =
  match !platform_cache with
  | Some p -> p
  | None ->
    let p = detect_platform () in
    platform_cache := Some p;
    p

let platform_name () =
  match platform () with
  | Macos -> "macOS"
  | Linux -> "Linux"
  | Windows -> "Windows"
  | Other s -> s

let supported_platform () =
  match platform () with Other _ -> false | _ -> true

let is_windows () = platform () = Windows
let is_macos () = platform () = Macos
let is_linux () = platform () = Linux

(* "the Mac" / "the computer" / "the PC" — used in prompts and messages, so
   that they read naturally everywhere. *)
let machine_name () =
  match platform () with
  | Macos -> "the Mac"
  | Windows -> "the PC"
  | _ -> "the computer"

let sleep_phrase () = "put " ^ machine_name () ^ " to sleep"

(* ------------------------------------------------------------------ *)
(* Enumeration backends                                               *)
(* ------------------------------------------------------------------ *)

type backend =
  | Lsappinfo    (* macOS: lsappinfo(1) — needs no TCC permission *)
  | Osascript    (* macOS: System Events via osascript (Automation permission) *)
  | Procfs       (* Linux: /proc scan, no external tools *)
  | Wmctrl       (* Linux/X11: wmctrl(1) — the windows currently on screen *)
  | Tasklist     (* Windows: tasklist(1), windowed processes only *)
  | Powershell   (* Windows: Get-Process, windowed processes only *)

let all_backends () =
  match platform () with
  | Macos -> [ Lsappinfo; Osascript ]
  | Linux -> [ Procfs; Wmctrl ]
  | Windows -> [ Tasklist; Powershell ]
  | Other _ -> []

let backend_to_string = function
  | Lsappinfo -> "lsappinfo"
  | Osascript -> "osascript"
  | Procfs -> "procfs"
  | Wmctrl -> "wmctrl"
  | Tasklist -> "tasklist"
  | Powershell -> "powershell"

(* Only the backends that exist on this platform are accepted, so `-b' fails
   with a helpful message instead of silently picking something odd. *)
let backend_of_string s =
  let b =
    match lowercase (String.trim s) with
    | "lsappinfo" -> Some Lsappinfo
    | "osascript" -> Some Osascript
    | "procfs" -> Some Procfs
    | "wmctrl" -> Some Wmctrl
    | "tasklist" -> Some Tasklist
    | "powershell" -> Some Powershell
    | _ -> None
  in
  match b with
  | Some b when List.mem b (all_backends ()) -> Some b
  | _ -> None

(* ------------------------------------------------------------------ *)
(* Parsing lsappinfo(1) output (macOS)                                *)
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
(* Parsing tab-separated "pid<TAB>name" output                        *)
(*   macOS:   System Events via osascript                             *)
(*   Windows: Get-Process via powershell                              *)
(* ------------------------------------------------------------------ *)

let parse_osascript out =
  String.split_on_char '\n' out
  |> List.filter_map (fun line ->
         let line = String.trim line in
         if line = "" then None
         else
           match String.index_opt line '\t' with
           | None -> None
           | Some i ->
             let pid_s = String.trim (String.sub line 0 i) in
             let name =
               String.trim (String.sub line (i + 1) (String.length line - i - 1))
             in
             (match int_of_string_opt pid_s with
              | Some pid when pid > 0 && name <> "" ->
                Some { name; pid; bundle = None }
              | _ -> None))

(* ------------------------------------------------------------------ *)
(* Parsing wmctrl(1) output (Linux/X11)                               *)
(* ------------------------------------------------------------------ *)

(* One line per window, e.g. (wmctrl -lpx)
     0x03a00007  0 3041 host Navigator.Firefox  Mozilla Firefox
   The column order of wmctrl versions varies, so the pid is taken from the
   first purely numeric field after the desktop number, the client machine is
   the field right after it, and the window class is recognised by its
   "instance.Class" shape; without a class the window title names the app.
   Windows are deduplicated by pid: the application, not the window, is the
   unit fq quits. *)
let split_ws s =
  String.split_on_char ' ' (String.map (fun c -> if c = '\t' then ' ' else c) s)
  |> List.filter (fun t -> t <> "")

let looks_like_wm_class t =
  match String.rindex_opt t '.' with
  | Some i when i > 0 && i < String.length t - 1 -> not (String.contains t '/')
  | _ -> false

(* Names this machine is known by: the client-machine column wmctrl prints is
   dropped by comparing against them. *)
let host_names () =
  let h = try Unix.gethostname () with _ -> "" in
  let short = match String.index_opt h '.' with Some i -> String.sub h 0 i | None -> h in
  List.filter (fun s -> s <> "") [ h; short ]

let parse_wmctrl out =
  let hosts = host_names () in
  let seen = Hashtbl.create 16 in
  String.split_on_char '\n' out
  |> List.filter_map (fun line ->
         let line = String.trim line in
         if line = "" || String.length line < 2 || String.sub line 0 2 <> "0x"
         then None
         else
           match split_ws line with
           | _id :: _desktop :: rest ->
             let pid, rest =
               match rest with
               | p :: tl when int_of_string_opt p <> None -> (int_of_string p, tl)
               | _ ->
                 (* no -p: the first numeric field is the pid *)
                 let rec find = function
                   | [] -> (0, [])
                   | t :: tl ->
                     (match int_of_string_opt t with
                      | Some n when n > 0 -> (n, tl)
                      | _ -> find tl)
                 in
                 find rest
             in
             if pid <= 0 then None
             else begin
               (* drop the client machine, and with it whichever column order
                  this wmctrl puts the window class in *)
               let rest = List.filter (fun t -> not (List.mem t hosts)) rest in
               let name =
                 match rest with
                 | k :: _ when looks_like_wm_class k ->
                   let i = String.rindex k '.' in
                   String.sub k (i + 1) (String.length k - i - 1)
                 | _ -> String.concat " " rest (* the window title *)
               in
               if name = "" || Hashtbl.mem seen pid then None
               else begin
                 Hashtbl.add seen pid ();
                 Some { name; pid; bundle = None }
               end
             end
           | _ -> None)

(* ------------------------------------------------------------------ *)
(* Parsing tasklist(1) CSV output (Windows)                           *)
(* ------------------------------------------------------------------ *)

(* Split one RFC-4180-ish CSV line: fields are quoted, embedded quotes are
   doubled. Enough for tasklist /FO CSV. *)
let parse_csv_line line =
  let n = String.length line in
  let fields = ref [] in
  let buf = Buffer.create 32 in
  let i = ref 0 in
  let in_quotes = ref false in
  let flush_field () =
    fields := Buffer.contents buf :: !fields;
    Buffer.clear buf
  in
  while !i < n do
    let c = line.[!i] in
    if !in_quotes then
      if c = '"' then
        if !i + 1 < n && line.[!i + 1] = '"' then begin
          Buffer.add_char buf '"';
          i := !i + 2
        end
        else begin
          in_quotes := false;
          incr i
        end
      else begin
        Buffer.add_char buf c;
        incr i
      end
    else if c = '"' then begin
      in_quotes := true;
      incr i
    end
    else if c = ',' then begin
      flush_field ();
      incr i
    end
    else begin
      Buffer.add_char buf c;
      incr i
    end
  done;
  flush_field ();
  List.rev !fields

(* tasklist /V /FO CSV /NH columns:
     "Image Name","PID","Session Name","Session#","Mem Usage","Status",
     "User Name","CPU Time","Window Title"
   Only rows with a window title are applications with a GUI: services and
   console processes report "N/A". The window title is the last field, the
   image name the first and the pid the second, which is stable across
   Windows versions even when a column is added. *)
let parse_tasklist out =
  String.split_on_char '\n' out
  |> List.filter_map (fun line ->
         let line = String.trim line in
         if line = "" then None
         else
           match parse_csv_line line with
           | image :: pid_s :: _ as fields -> (
             let title =
               match List.rev fields with
               | t :: _ -> String.trim t
               | [] -> ""
             in
             if title = "" || lowercase title = "n/a" then None
             else
               match int_of_string_opt (String.trim pid_s) with
               | Some pid when pid > 0 ->
                 let name =
                   if Filename.check_suffix (lowercase image) ".exe" then
                     String.sub image 0 (String.length image - 4)
                   else image
                 in
                 Some { name; pid; bundle = None }
               | _ -> None)
           | [] | [ _ ] -> None)

(* ------------------------------------------------------------------ *)
(* Linux: /proc and .desktop entries                                  *)
(* ------------------------------------------------------------------ *)

(* Field names carry a p_ prefix because [pid] would otherwise be ambiguous
   with {!app}.pid when a record is not annotated (OCaml resolves a bare
   [x.pid] to the most recently defined record type). *)
type proc_info = {
  p_pid : int;
  p_ppid : int;
  p_pgrp : int;
  p_session : int;
  p_tty_nr : int;
  p_tpgid : int;
  p_comm : string;
}

(* /proc/<pid>/stat. The comm field may contain spaces and parentheses, so it
   is delimited by the first '(' and the last ')' — everything after that is
   state, ppid, pgrp, session, tty_nr, tpgid, ... *)
let parse_proc_stat s =
  match (String.index_opt s '(', String.rindex_opt s ')') with
  | Some o, Some c when c > o ->
    let pid_s = String.trim (String.sub s 0 o) in
    let comm = String.sub s (o + 1) (c - o - 1) in
    let rest = String.sub s (c + 1) (String.length s - c - 1) in
    let fields = split_ws rest in
    (match (int_of_string_opt pid_s, fields) with
     | Some pid, _state :: ppid :: pgrp :: session :: tty :: tpgid :: _ -> (
       match
         ( int_of_string_opt ppid,
           int_of_string_opt pgrp,
           int_of_string_opt session,
           int_of_string_opt tty,
           int_of_string_opt tpgid )
       with
       | Some ppid, Some pgrp, Some session, Some tty_nr, Some tpgid ->
         Some
           { p_pid = pid; p_ppid = ppid; p_pgrp = pgrp; p_session = session;
             p_tty_nr = tty_nr; p_tpgid = tpgid; p_comm = comm }
       | _ -> None)
     | _ -> None)
  | _ -> None

(* /proc/<pid>/environ is NUL-separated KEY=VALUE. A process belongs to a
   graphical session when DISPLAY or WAYLAND_DISPLAY is set to something
   non-empty. *)
let has_graphical_env environ =
  String.split_on_char '\000' environ
  |> List.exists (fun kv ->
         match String.index_opt kv '=' with
         | None -> false
         | Some i ->
           let k = String.sub kv 0 i in
           let v = String.sub kv (i + 1) (String.length kv - i - 1) in
           (k = "DISPLAY" || k = "WAYLAND_DISPLAY") && String.trim v <> "")

(* Key/value pairs of the [Desktop Entry] group of a .desktop file. Only the
   first occurrence of a key is kept, so a localized Name[xx]= after Name=
   cannot win. *)
let parse_desktop_entry s =
  let rec go in_group acc = function
    | [] -> List.rev acc
    | line :: rest ->
      let l = String.trim line in
      if l = "" || l.[0] = '#' then go in_group acc rest
      else if l.[0] = '[' then go (l = "[Desktop Entry]") acc rest
      else if not in_group then go in_group acc rest
      else (
        match String.index_opt l '=' with
        | None -> go in_group acc rest
        | Some i ->
          let k = String.trim (String.sub l 0 i) in
          let v = String.sub l (i + 1) (String.length l - i - 1) in
          let acc = if List.mem_assoc k acc then acc else (k, v) :: acc in
          go in_group acc rest)
  in
  go false [] (String.split_on_char '\n' s)

(* The program a .desktop Exec= line runs: its basename. "env FOO=bar gimp
   %U" -> "gimp", including quoted commands with spaces in their path.
   Launchers that merely wrap another app (flatpak, snap) are ignored: their
   Exec= does not name the application binary. *)
let first_exec_token s =
  let s = String.trim s in
  let n = String.length s in
  if n = 0 then None
  else if s.[0] = '"' then (
    match String.index_from_opt s 1 '"' with
    | Some i -> Some (String.sub s 1 (i - 1), String.sub s (i + 1) (n - i - 1))
    | None -> Some (String.sub s 1 (n - 1), ""))
  else
    let rec find i =
      if i >= n then None
      else if s.[i] = ' ' || s.[i] = '\t' then Some i
      else find (i + 1)
    in
    match find 0 with
    | Some i -> Some (String.sub s 0 i, String.sub s (i + 1) (n - i - 1))
    | None -> Some (s, "")

let desktop_exec_basename exec =
  let rec pick s =
    match first_exec_token s with
    | None -> None
    | Some (tok, rest) ->
      if Filename.basename tok = "env" then pick rest
      else if String.contains tok '=' && not (String.contains tok '/') then
        pick rest (* VAR=value prefix *)
      else Some (Filename.basename tok)
  in
  match pick exec with
  | Some b when b = "" || b = "flatpak" || b = "snap" -> None
  | other -> other

(* exe basename (lowercased) -> (display name, .desktop path). Earlier
   directories win, so a user's entry overrides the system one. *)
let desktop_name_map ~dirs =
  List.fold_left
    (fun acc dir ->
      match Sys.readdir dir with
      | exception _ -> acc
      | entries ->
        Array.sort String.compare entries;
        Array.fold_left
          (fun acc entry ->
            if not (Filename.check_suffix entry ".desktop") then acc
            else
              let path = Filename.concat dir entry in
              match read_file path with
              | Error _ -> acc
              | Ok text -> (
                let kv = parse_desktop_entry text in
                match (List.assoc_opt "Name" kv, List.assoc_opt "Exec" kv) with
                | Some name, Some exec when String.trim name <> "" -> (
                  match desktop_exec_basename exec with
                  | Some b ->
                    let key = lowercase b in
                    if List.mem_assoc key acc then acc
                    else (key, (String.trim name, path)) :: acc
                  | None -> acc)
                | _ -> acc))
          acc entries)
    [] dirs

(* Session infrastructure: window managers, compositors, panels, session and
   sound daemons, portals, input methods. These run in a graphical session
   too, but they are not applications anyone wants in the Force Quit list. *)
let linux_infrastructure =
  [ "xorg"; "x"; "xwayland"; "weston"; "gamescope"; "gnome-shell";
    "gnome-session"; "gnome-session-binary"; "gnome-session-ctl"; "plasmashell";
    "plasma_session"; "kwin"; "kwin_x11"; "kwin_wayland"; "mutter"; "marco";
    "xfwm4"; "xfwm"; "cinnamon"; "compiz"; "picom"; "compton"; "sway"; "i3";
    "bspwm"; "openbox"; "fluxbox"; "icewm"; "dwm"; "awesome"; "xmonad";
    "herbstluftwm"; "labwc"; "wayfire"; "river"; "hyprland"; "enlightenment";
    "lxqt-panel"; "xfce4-panel"; "gnome-panel"; "mate-panel"; "tint2";
    "polybar"; "waybar"; "slstatus"; "dwmblocks"; "latte-dock"; "plank";
    "docky"; "cairo-dock"; "budgie-panel"; "systemd"; "init"; "dbus-daemon";
    "dbus-broker"; "dbus-launch"; "dbus-run-session"; "pipewire";
    "pipewire-pulse"; "pipewire-media-session"; "wireplumber"; "pulseaudio";
    "rtkit-daemon"; "dconf-service"; "gnome-keyring-daemon"; "ssh-agent";
    "gpg-agent"; "at-spi2-registryd"; "at-spi-bus-launcher"; "ibus-daemon";
    "ibus-x11"; "fcitx5"; "lightdm"; "gdm"; "gdm3"; "sddm"; "sddm-helper";
    "kdeconnectd"; "kactivitymanagerd"; "klauncher"; "kaccess"; "ksmserver";
    "xembedsniproxy"; "xsettingsd"; "unity-settings-daemon"; "gnome-software-service" ]

let linux_infrastructure_prefixes =
  [ "gsd-"; "gvfsd"; "tracker-"; "evolution-"; "ibus-"; "fcitx"; "kded";
    "kglobalaccel"; "kwalletd"; "kiod"; "polkit"; "gnome-shell-"; "xdg-";
    "at-spi"; "kwin_"; "kscreen"; "powerdevil"; "plasma-"; "gnome-session-" ]

let is_linux_infrastructure name =
  let n = lowercase name in
  List.mem n linux_infrastructure
  || List.exists (fun p -> String.starts_with ~prefix:p n) linux_infrastructure_prefixes

let proc_root_default = "/proc"

let proc_root () =
  match env_trim "FQ_PROC_ROOT" with Some p -> p | None -> proc_root_default

let xdg_data_home () =
  match env_trim "XDG_DATA_HOME" with
  | Some p -> p
  | None -> (
    match env_trim "HOME" with
    | Some h -> Filename.concat h ".local/share"
    | None -> "/usr/local/share")

let desktop_dirs () =
  match env_trim "FQ_DESKTOP_DIRS" with
  | Some dirs ->
    String.split_on_char ':' dirs |> List.filter (fun d -> String.trim d <> "")
  | None ->
    [ "/usr/share/applications"; "/usr/local/share/applications";
      Filename.concat (xdg_data_home ()) "applications";
      "/var/lib/flatpak/exports/share/applications";
      Filename.concat (xdg_data_home ()) "flatpak/exports/share/applications" ]

(* Executable basename of a process: /proc/<pid>/exe when it can be read,
   otherwise the first cmdline word, otherwise comm. *)
let proc_exe ~proc_root ~pid ~fallback =
  let dir = Filename.concat proc_root (string_of_int pid) in
  match Unix.readlink (Filename.concat dir "exe") with
  | p -> Filename.basename p
  | exception _ -> (
    match read_file (Filename.concat dir "cmdline") with
    | Ok s -> (
      match String.index_opt s '\000' with
      | Some i when i > 0 -> Filename.basename (String.sub s 0 i)
      | _ -> fallback)
    | Error _ -> fallback)

(* Shells: a shell that has a controlling terminal is somebody's session, not
   an application. *)
let shell_comms =
  [ "sh"; "bash"; "zsh"; "fish"; "dash"; "ksh"; "mksh"; "tcsh"; "csh"; "ash";
    "elvish"; "nu"; "xonsh"; "tmux"; "screen"; "login"; "sshd" ]

(* Is this process a desktop application?
   - it must not be a console program: not the job its terminal is running in
     the foreground (a shell, an editor, a build running in a terminal), and
     not a shell that has a terminal at all. A program the terminal runs in
     the background (an application started with "app &") still counts, as
     does anything that detached from the terminal — which is how desktop
     environments and launchers start applications; and
   - it must not be session infrastructure. *)
let is_desktop_app info =
  let console_job =
    info.p_tty_nr <> 0
    && (info.p_pgrp = info.p_tpgid
       || List.mem (lowercase info.p_comm) shell_comms)
  in
  (not console_job) && not (is_linux_infrastructure info.p_comm)

let list_apps_procfs ~proc_root ~desktop_dirs =
  match Sys.readdir proc_root with
  | exception Sys_error e ->
    Error (Printf.sprintf "cannot read %s: %s" proc_root e)
  | entries ->
    let dir_of pid = Filename.concat proc_root (string_of_int pid) in
    (* every process of the tree, so that parents can be looked up *)
    let infos : (int, proc_info) Hashtbl.t = Hashtbl.create 256 in
    Array.iter
      (fun entry ->
        match int_of_string_opt entry with
        | None | Some 0 -> ()
        | Some _ -> (
          match read_file (Filename.concat (Filename.concat proc_root entry) "stat") with
          | Error _ -> ()
          | Ok stat -> (
            match parse_proc_stat stat with
            | Some i -> Hashtbl.replace infos i.p_pid i
            | None -> ())))
      entries;
    let ppid_of pid =
      match Hashtbl.find_opt infos pid with Some i -> Some i.p_ppid | None -> None
    in
    (* candidate applications: desktop processes of a graphical session *)
    let candidates =
      Hashtbl.fold
        (fun _ i acc ->
          if not (is_desktop_app i) then acc
          else
            match read_file (Filename.concat (dir_of i.p_pid) "environ") with
            | Error _ -> acc (* not ours to look at *)
            | Ok environ ->
              if has_graphical_env environ then i :: acc else acc)
        infos []
    in
    let exe_of i = lowercase (proc_exe ~proc_root ~pid:i.p_pid ~fallback:i.p_comm) in
    let exe_by_pid = Hashtbl.create 64 in
    List.iter (fun i -> Hashtbl.replace exe_by_pid i.p_pid (exe_of i)) candidates;
    (* Helper processes of a multi-process application run the application's
       own binary (a browser's renderer processes, an editor's language
       server): only the topmost process of such a chain is the application.
       A process started by a *different* application (a terminal opened from
       a file manager, say) is an application of its own. *)
    let is_helper i =
      let exe = try Hashtbl.find exe_by_pid i.p_pid with Not_found -> "" in
      let rec up p depth =
        if depth <= 0 then false
        else
          match ppid_of p with
          | Some pp when pp > 1 -> (
            match Hashtbl.find_opt exe_by_pid pp with
            | Some other -> other = exe
            | None -> up pp (depth - 1))
          | _ -> false
      in
      up i.p_pid 64
    in
    let names = desktop_name_map ~dirs:desktop_dirs in
    let apps =
      List.filter_map
        (fun i ->
          let exe = try Hashtbl.find exe_by_pid i.p_pid with Not_found -> "" in
          if exe = "" || is_linux_infrastructure exe || is_helper i then None
          else
            let name, bundle =
              match List.assoc_opt exe names with
              | Some (n, path) -> (n, Some path)
              | None -> (exe, None)
            in
            Some { name; pid = i.p_pid; bundle })
        candidates
    in
    Ok (sort_apps apps)

(* ------------------------------------------------------------------ *)
(* Enumerating running applications                                   *)
(* ------------------------------------------------------------------ *)

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

(* Single quotes and [char]9 (a tab) only: the script has to survive being
   passed through the Windows command line, where double quotes and backticks
   are nothing but trouble. *)
let powershell_script =
  "Get-Process | Where-Object { $_.MainWindowTitle -ne '' } | ForEach-Object { \
   $_.Id.ToString() + [char]9 + $_.ProcessName }"

(* Run an enumeration command, or read its output from FQ_ENUM_OUTPUT when the
   test suite wants to drive a backend on another platform. *)
let run_backend argv =
  match env_trim "FQ_ENUM_OUTPUT" with
  | Some path -> read_file path
  | None -> run_capture argv

let list_apps = function
  | Lsappinfo -> (
    match run_backend [| "lsappinfo"; "list" |] with
    | Ok out -> Ok (sort_apps (parse_lsappinfo out))
    | Error e -> Error e)
  | Osascript -> (
    match run_backend [| "osascript"; "-e"; osascript_script |] with
    | Ok out -> Ok (sort_apps (parse_osascript out))
    | Error e -> Error e)
  | Procfs -> list_apps_procfs ~proc_root:(proc_root ()) ~desktop_dirs:(desktop_dirs ())
  | Wmctrl -> (
    match run_backend [| "wmctrl"; "-lpx" |] with
    | Ok out -> Ok (sort_apps (parse_wmctrl out))
    | Error e -> Error e)
  | Tasklist -> (
    match run_backend [| "tasklist.exe"; "/V"; "/FO"; "CSV"; "/NH" |] with
    | Ok out -> Ok (sort_apps (parse_tasklist out))
    | Error e -> Error e)
  | Powershell -> (
    match
      run_backend
        [| "powershell.exe"; "-NoProfile"; "-NonInteractive"; "-Command";
           powershell_script |]
    with
    | Ok out -> Ok (sort_apps (parse_osascript out))
    | Error e -> Error e)

let auto_list_apps () =
  let rec go = function
    | [] ->
      Error
        (Printf.sprintf
           "could not enumerate running applications (every %s backend failed)"
           (platform_name ()))
    | b :: rest -> (
      match list_apps b with
      | Ok apps -> Ok (b, apps)
      | Error _ -> go rest)
  in
  go (all_backends ())

(* ------------------------------------------------------------------ *)
(* Name matching                                                      *)
(* ------------------------------------------------------------------ *)

let normalize_name s =
  let s = String.trim s in
  let s =
    if Filename.check_suffix s ".app" then Filename.chop_suffix s ".app" else s
  in
  lowercase s

type name_match = Unique of app | None_found | Ambiguous of app list

let match_name apps name =
  let target = normalize_name name in
  let lower a = lowercase a.name in
  let exact = List.filter (fun a -> lower a = target) apps in
  match exact with
  | [ a ] -> Unique a
  | _ :: _ -> Ambiguous exact
  | [] -> (
    (* no exact match: accept an unambiguous substring match *)
    let subs = List.filter (fun a -> contains_sub (lower a) target) apps in
    match subs with
    | [ a ] -> Unique a
    | _ :: _ -> Ambiguous subs
    | [] -> None_found)

let find_pid (apps : app list) pid = List.find_opt (fun a -> a.pid = pid) apps

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
(* Process introspection                                              *)
(* ------------------------------------------------------------------ *)

(* Windows has no ps(1); the whole process table is fetched once (with
   PowerShell) and cached, which also keeps the ancestor walk to a single
   subprocess. *)
let win_table : (int, int * string) Hashtbl.t = Hashtbl.create 256
let win_table_loaded = ref false

let load_win_table () =
  if not !win_table_loaded then begin
    win_table_loaded := true;
    let script =
      "Get-CimInstance Win32_Process | ForEach-Object { \
       $_.ProcessId.ToString() + [char]9 + $_.ParentProcessId.ToString() + \
       [char]9 + $_.Name }"
    in
    match
      run_capture
        [| "powershell.exe"; "-NoProfile"; "-NonInteractive"; "-Command"; script |]
    with
    | Error _ -> ()
    | Ok out ->
      String.split_on_char '\n' out
      |> List.iter (fun line ->
             match String.split_on_char '\t' (String.trim line) with
             | [ p; pp; name ] -> (
               match (int_of_string_opt p, int_of_string_opt pp) with
               | Some p, Some pp -> Hashtbl.replace win_table p (pp, String.trim name)
               | _ -> ())
             | _ -> ())
  end

(* Process group of another process. On Linux this is read from /proc; both
   Linux and macOS fall back to ps(1). [None] on Windows, which has no process
   groups in the POSIX sense. *)
let pgid_of pid =
  if is_windows () then None
  else
    let from_proc () =
      match read_file (Filename.concat (Filename.concat (proc_root ()) (string_of_int pid)) "stat") with
      | Ok s -> Option.map (fun i -> i.p_pgrp) (parse_proc_stat s)
      | Error _ -> None
    in
    match if is_linux () then from_proc () else None with
    | Some pg -> Some pg
    | None -> (
      match run_capture [| "ps"; "-o"; "pgid="; "-p"; string_of_int pid |] with
      | Ok s -> (
        try
          let t = String.trim s in
          if t = "" then None else Some (int_of_string t)
        with Failure _ -> None)
      | Error _ -> None)

(* Parent pid of another process. Returns None when the process is gone or
   cannot be inspected. *)
let parent_pid_of pid =
  if is_windows () then begin
    load_win_table ();
    match Hashtbl.find_opt win_table pid with
    | Some (ppid, _) -> Some ppid
    | None -> None
  end
  else
    let from_proc () =
      match read_file (Filename.concat (Filename.concat (proc_root ()) (string_of_int pid)) "stat") with
      | Ok s -> Option.map (fun i -> i.p_ppid) (parse_proc_stat s)
      | Error _ -> None
    in
    match if is_linux () then from_proc () else None with
    | Some pp -> Some pp
    | None -> (
      match run_capture [| "ps"; "-o"; "ppid="; "-p"; string_of_int pid |] with
      | Ok s -> (
        try
          let t = String.trim s in
          if t = "" then None else Some (int_of_string t)
        with Failure _ -> None)
      | Error _ -> None)

(* Pids of every ancestor of [pid], nearest first, stopping before launchd /
   init (pid 1). Used to recognise "this terminal": the GUI application
   hosting the process that ran fq is the first ancestor that shows up in the
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

(* Pids of the descendants of [pid], nearest first. Linux only: elsewhere the
   process group is the unit that gets killed. Excludes nothing here — the
   caller filters out fq's own process and its ancestors. *)
let descendants_of pid =
  if not (is_linux ()) then []
  else
    let root = proc_root () in
    match Sys.readdir root with
    | exception _ -> []
    | entries ->
      let table = Hashtbl.create 256 in
      Array.iter
        (fun entry ->
          match int_of_string_opt entry with
          | None -> ()
          | Some p -> (
            match read_file (Filename.concat (Filename.concat root entry) "stat") with
            | Ok s -> (
              match parse_proc_stat s with
              | Some i -> Hashtbl.replace table p i.p_ppid
              | None -> ())
            | Error _ -> ()))
        entries;
      let out = ref [] in
      let rec walk p depth =
        if depth > 0 then
          Hashtbl.iter
            (fun child ppid ->
              if ppid = p && child <> pid && not (List.mem child !out) then begin
                out := child :: !out;
                walk child (depth - 1)
              end)
            table
      in
      walk pid 32;
      List.rev !out

(* Executable basename of a process, for protecting --pid targets that could
   not be resolved against the enumerated application list. *)
let executable_of_pid pid =
  if is_windows () then begin
    load_win_table ();
    match Hashtbl.find_opt win_table pid with
    | Some (_, name) -> Some (Filename.basename name)
    | None -> None
  end
  else
    match run_capture [| "ps"; "-o"; "comm="; "-p"; string_of_int pid |] with
    | Ok s ->
      let p = String.trim s in
      if p = "" then None else Some (try Filename.basename p with _ -> p)
    | Error _ -> None

(* Process group of this process. Killing that group with [SIGKILL -pgid]
   would kill fq itself — the "self process" — along with every other process
   sharing the group, so [force_quit_pid] must never signal it. OCaml's Unix
   module has no [getpgrp], so the group is read like any other. *)
let own_process_group () = if is_windows () then None else pgid_of (Unix.getpid ())

(* ------------------------------------------------------------------ *)
(* Force quitting                                                     *)
(* ------------------------------------------------------------------ *)

type quit_outcome = Terminated | Already_gone

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

let permission_hint () =
  if is_windows () then "access denied — try again as Administrator"
  else "permission denied — try again with sudo"

(* Kill every target; success when at least one was killed, and "already gone"
   when they had all exited. *)
let attempt_kills targets =
  let killed = ref false in
  let gone = ref false in
  let err = ref None in
  List.iter
    (fun t ->
      match attempt_kill t with
      | Kill_ok -> killed := true
      | Kill_gone -> gone := true
      | Kill_perm -> if !err = None then err := Some (permission_hint ())
      | Kill_error ->
        if !err = None then err := Some "the process could not be terminated")
    targets;
  if !killed then Ok Terminated
  else if !gone then Ok Already_gone
  else
    Error
      (match !err with
       | Some e -> e
       | None -> "could not terminate the process (it has already exited)")

(* Windows: taskkill /T /F takes the whole process tree down, which is the
   equivalent of killing a process group on POSIX. taskkill reports a pid that
   is already gone as "not found" (on stderr, exit status 128) and a pid it may
   not touch as "Access is denied". *)
let windows_force_quit_pid pid =
  match
    run_capture_all [| "taskkill.exe"; "/PID"; string_of_int pid; "/T"; "/F" |]
  with
  | Ok _ -> Ok Terminated
  | Error e ->
    let low = lowercase e in
    if
      contains_sub low "not found"
      || contains_sub low "no running instance"
      || contains_sub low "exited with status 128"
    then Ok Already_gone
    else if contains_sub low "access is denied" then Error (permission_hint ())
    else Error e

let force_quit_pid pid =
  let me = Unix.getpid () in
  if pid = me then Error "refusing to force-quit fq itself"
  else if is_windows () then windows_force_quit_pid pid
  else begin
    (* When the process leads its own group, SIGKILL the whole group first so
       that helper processes die too; fall back to the single process. Never
       our own process group: that would take fq (and the work still to do,
       such as -s/--sleep) down with the victim. If the victim is the leader
       of our group, only the victim is killed, so fq survives. *)
    let own_group = own_process_group () in
    match pgid_of pid with
    | Some pg when pg = pid && Some pg <> own_group -> attempt_kills [ -pg; pid ]
    | _ ->
      if is_linux () then begin
        (* The victim does not lead a group (an app started in the foreground
           of a terminal, say): kill its process tree, like taskkill /T, but
           never fq itself or the processes it runs under — killing those
           would take fq down before it could finish (e.g. before -s). *)
        let self = me :: ancestor_pids ~pid:me in
        let kids = List.filter (fun p -> not (List.mem p self)) (descendants_of pid) in
        attempt_kills (pid :: List.rev kids)
      end
      else attempt_kills [ pid ]
  end

let force_quit a = force_quit_pid a.pid

(* ------------------------------------------------------------------ *)
(* Protected system applications                                      *)
(* ------------------------------------------------------------------ *)

(* Names are compared case-insensitively, ignoring spaces and a trailing
   .app/.exe/.com/.desktop ("Control Center" == "controlcenter" ==
   "ControlCenter.exe"). Only those known suffixes are stripped, so a name
   that contains dots (org.gnome.Nautilus) keeps them. *)
let normalize_app_name s =
  let strip s suffix =
    if Filename.check_suffix s suffix then Filename.chop_suffix s suffix else s
  in
  let s = lowercase (String.trim s) in
  let s = List.fold_left strip s [ ".app"; ".exe"; ".com"; ".desktop" ] in
  String.concat "" (String.split_on_char ' ' s)

(* Core system UI processes that must not be force-quit by accident: they
   underpin the whole session. [fq] refuses to kill these unless -f/--force is
   given. *)
let protected_names () =
  match platform () with
  | Macos ->
    [ "finder"; "loginwindow"; "windowmanager"; "dock"; "systemuiserver";
      "controlcenter"; "notificationcenter" ]
  | Linux ->
    [ "systemd"; "init"; "gnome-shell"; "plasmashell"; "kwin_x11";
      "kwin_wayland"; "mutter"; "marco"; "xfwm4"; "cinnamon"; "compiz"; "sway";
      "Xorg"; "Xwayland"; "dbus-daemon"; "dbus-broker"; "pipewire";
      "wireplumber"; "pulseaudio"; "gnome-session"; "ksmserver";
      "xfce4-session"; "mate-session"; "lxsession"; "lightdm"; "gdm"; "sddm" ]
  | Windows ->
    [ "explorer"; "winlogon"; "csrss"; "wininit"; "services"; "lsass"; "smss";
      "dwm"; "sihost"; "taskhostw"; "ctfmon"; "fontdrvhost"; "system";
      "registry"; "memcompression"; "idle"; "svchost"; "searchhost";
      "startmenuexperiencehost"; "shellexperiencehost"; "runtimebroker";
      "textinputhost"; "securityhealthservice"; "wmiprvse" ]
  | Other _ -> []

let is_protected_name s =
  List.mem (normalize_app_name s) (List.map normalize_app_name (protected_names ()))

let is_protected a = is_protected_name a.name

(* ------------------------------------------------------------------ *)
(* Sleep (-s/--sleep)                                                 *)
(* ------------------------------------------------------------------ *)

(* Commands that put the machine to sleep, best first. FQ_SLEEP_CMD overrides
   them so the sleep path can be exercised (and the machine kept awake) by the
   tests. *)
let sleep_fallbacks () =
  match env_trim "FQ_SLEEP_CMD" with
  | Some c -> [ [| c |] ]
  | None -> (
    match platform () with
    | Macos -> [ [| "pmset"; "sleepnow" |] ]
    | Linux -> [ [| "systemctl"; "suspend" |]; [| "pm-suspend" |]; [| "zzz" |] ]
    | Windows ->
      [ [| "powershell.exe"; "-NoProfile"; "-NonInteractive"; "-Command";
           "Add-Type -AssemblyName System.Windows.Forms; \
            [System.Windows.Forms.Application]::SetSuspendState('Suspend',$false,$false)" |];
        [| "rundll32.exe"; "powrprof.dll,SetSuspendState"; "0,1,0" |] ]
    | Other _ -> [ [| "pmset"; "sleepnow" |] ])

let sleep_invocation () =
  match sleep_fallbacks () with
  | cmd :: _ -> cmd
  | [] -> [| "pmset"; "sleepnow" |]

(* Short, readable form of the sleep command, for help text and messages. *)
let sleep_command_display () =
  match env_trim "FQ_SLEEP_CMD" with
  | Some c -> c
  | None -> (
    match platform () with
    | Macos -> "pmset sleepnow"
    | Linux -> "systemctl suspend"
    | Windows -> "SetSuspendState"
    | Other _ -> String.concat " " (Array.to_list (sleep_invocation ())))

(* Put the machine to sleep immediately. *)
let sleep_now () =
  let rec go = function
    | [] ->
      Error
        (Printf.sprintf "no working sleep command was found (tried %s)"
           (String.concat ", "
              (List.map
                 (fun c -> String.concat " " (Array.to_list c))
                 (sleep_fallbacks ()))))
    | cmd :: rest -> (
      match run_capture cmd with
      | Ok _ -> Ok ()
      | Error e -> if rest = [] then Error e else go rest)
  in
  if env_trim "FQ_SLEEP_CMD" <> None then
    (* An explicit command is used as given: no fallbacks, so the tests see
       exactly the one invocation they configured. *)
    match run_capture (sleep_invocation ()) with Ok _ -> Ok () | Error e -> Error e
  else go (sleep_fallbacks ())

let quote_argv argv =
  String.concat " " (Array.to_list (Array.map Filename.quote argv))

let ps_quote s = "'" ^ String.concat "''" (String.split_on_char '\'' s) ^ "'"

(* Arm a fully detached helper that waits [delay] seconds and then puts the
   machine to sleep. Needed when the force-quit list includes the application
   running this terminal: killing that app can take fq's own process group
   with it, so fq may not live long enough to run the sleep itself. If fq
   survives, it sleeps directly and this helper simply finds the machine
   already asleep. *)
let arm_delayed_sleep_posix ~delay =
  let cmd = Printf.sprintf "sleep %g; exec %s" delay (quote_argv (sleep_invocation ())) in
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

(* Windows: write a small PowerShell script that waits, sleeps and removes
   itself, then start it detached (Start-Process) and hidden. It must not stay
   attached to fq's console: killing the terminal that hosts fq would take it
   down with us. *)
let arm_delayed_sleep_windows ~delay =
  let path =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "fq-sleep-%d.ps1" (Unix.getpid ()))
  in
  let argv = sleep_invocation () in
  let call =
    "& " ^ ps_quote (Array.get argv 0)
    ^ String.concat ""
        (List.map
           (fun a -> " " ^ ps_quote a)
           (Array.to_list (Array.sub argv 1 (Array.length argv - 1))))
  in
  let body =
    String.concat "\r\n"
      [ "$ErrorActionPreference = 'SilentlyContinue'";
        Printf.sprintf "Start-Sleep -Milliseconds %d" (int_of_float (delay *. 1000.));
        call;
        "Remove-Item -LiteralPath $MyInvocation.MyCommand.Path -Force" ]
    ^ "\r\n"
  in
  (try
     let oc = open_out_bin path in
     output_string oc body;
     close_out oc
   with _ -> ());
  ignore
    (run_capture
       [| "powershell.exe"; "-NoProfile"; "-NonInteractive"; "-Command";
          Printf.sprintf
            "Start-Process -WindowStyle Hidden -FilePath 'powershell.exe' \
             -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',%s)"
            (ps_quote path) |])

let arm_delayed_sleep ~delay =
  if is_windows () then arm_delayed_sleep_windows ~delay
  else arm_delayed_sleep_posix ~delay
