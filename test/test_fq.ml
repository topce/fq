(* Unit tests for the Fq library: the parsers of every enumeration backend
   (lsappinfo / osascript on macOS, /proc and wmctrl on Linux, tasklist and
   PowerShell on Windows), the procfs enumeration itself, name matching and
   the process-tree helpers. Run with: dune runtest *)

open Fq

let failures = ref 0
let checks = ref 0

let check name cond =
  incr checks;
  if cond then Printf.printf "ok   %s\n" name
  else begin
    incr failures;
    Printf.printf "FAIL %s\n" name
  end

(* Printed instead of a check when the environment cannot provide something
   the check needs (ps(1) is not available in every sandbox). *)
let skip name why =
  Printf.printf "skip %s (%s)\n" name why

let lsappinfo_fixture =
  {|
 1) "Finder" ASN:0x0-0x10010: 
    bundleID="com.apple.finder"
    bundle path="/System/Library/CoreServices/Finder.app"
    executable path="/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder"
    pid = 624 type="Foreground" flavor=3 Version="1828.6.1" fileType="FNDR" creator="MACS" Arch=ARM64 
    childASNs: 
    coalition: 372
    checkin time = 2026/09/03 19:26:07 ( 2 days, 23 hours, 25 minutes, 16.0986 seconds ago )
 2) "Background Thing" ASN:0x0-0x8008: 
    pid = 607 !signalled type="BackgroundOnly" flavor=3 Version=[ NULL ] 
    bundle path="/usr/libexec/BackgroundThing"
 3) "Firefox Developer Edition" ASN:0x0-0x30030: 
    pid = 89719 type="Foreground" flavor=3 fileType="APPL" creator="MOZB" Arch=ARM64 
 4) "Safari" ASN:0x0-0x40040: 
    pid = 88043 type="Foreground" flavor=3 fileType="APPL" creator="sfri" Arch=ARM64 sandboxed 
 5) "Weird \"Quote\" App" ASN:0x0-0x50050: 
    pid = 5 type="Foreground" flavor=3 fileType="APPL"
|}

let osascript_fixture = "624\tFinder\n88043\tSafari\n89719\tfirefox\n\n"

(* wmctrl -lpx. Two windows of one application (deduplicated by pid), one
   window whose class column comes before the client machine (wmctrl versions
   differ in that), one without a usable class. *)
let host = try Unix.gethostname () with _ -> "localhost"

let wmctrl_fixture =
  Printf.sprintf
    "0x03a00007  0 3041 %s Navigator.Firefox  Mozilla Firefox\n\
     0x03a0000b  0 3041 %s Navigator.Firefox  Mozilla Firefox (Private)\n\
     0x05200003  0 5123 %s gnome-terminal-server.Gnome-terminal  user@%s: ~\n\
     0x07000001  0 7001 Calendar.Gnome-calendar %s Calendar\n\
     0x06000002  0 6001 %s  An Untitled Window\n"
    host host host host host host

(* tasklist /V /FO CSV /NH *)
let tasklist_fixture =
  "\"chrome.exe\",\"1234\",\"Console\",\"1\",\"123,456 K\",\"Running\",\"DOM\\user\",\"0:00:01\",\"Google Chrome\"\r\n\
   \"chrome.exe\",\"1235\",\"Console\",\"1\",\"80,000 K\",\"Running\",\"DOM\\user\",\"0:00:00\",\"N/A\"\r\n\
   \"services.exe\",\"660\",\"Services\",\"0\",\"4,096 K\",\"Running\",\"SYSTEM\",\"0:00:00\",\"N/A\"\r\n\
   \"notepad.exe\",\"4321\",\"Console\",\"1\",\"12,000 K\",\"Running\",\"DOM\\user\",\"0:00:00\",\"Untitled - Notepad\"\r\n\
   \"weird \"\"quoted\"\".exe\",\"777\",\"Console\",\"1\",\"1 K\",\"Running\",\"DOM\\user\",\"0:00:00\",\"Some, title\"\r\n\
   \"bad.exe\",\"not-a-pid\",\"Console\",\"1\",\"1 K\",\"Running\",\"DOM\\user\",\"0:00:00\",\"Ignored\"\r\n"

let mk name pid = { name; pid; bundle = None }

let has_sub s sub =
  let n = String.length s and m = String.length sub in
  let rec go i = i + m <= n && (String.sub s i m = sub || go (i + 1)) in
  m > 0 && go 0

(* ------------------------------------------------------------------ *)
(* Temporary directories (procfs / .desktop fixtures)                  *)
(* ------------------------------------------------------------------ *)

let rec rm_rf path =
  match (try Some (Sys.is_directory path) with _ -> None) with
  | Some true ->
    Array.iter
      (fun e -> rm_rf (Filename.concat path e))
      (try Sys.readdir path with _ -> [||]);
    (try Unix.rmdir path with _ -> ())
  | Some false -> (try Sys.remove path with _ -> ())
  | None -> ()

let with_temp_dir f =
  let dir = Filename.temp_file "fq-test-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)

let write_file path contents =
  let oc = open_out_bin path in
  output_string oc contents;
  close_out oc

let mkdir_p path = try Unix.mkdir path 0o755 with _ -> ()

(* ------------------------------------------------------------------ *)
(* A /proc-like fixture tree                                           *)
(* ------------------------------------------------------------------ *)

(* <proc root>/<pid>/{stat,environ,exe} for one synthetic process. [stat]
   follows the real format "pid (comm) state ppid pgrp session tty tpgid ...";
   without an explicit [tpgid] the process is the job its terminal runs in the
   foreground, as a shell or an editor would be. *)
let proc_entry ?tpgid root ~pid ~comm ~ppid ~pgrp ~tty_nr ~environ ~exe =
  let tpgid =
    match tpgid with Some t -> t | None -> if tty_nr = 0 then 0 else pgrp
  in
  let dir = Filename.concat root (string_of_int pid) in
  mkdir_p dir;
  write_file
    (Filename.concat dir "stat")
    (Printf.sprintf
       "%d (%s) S %d %d %d %d %d 0 -1 4194304 1 0 0 0 0 0 20 0 1 0 1 0\n" pid
       comm ppid pgrp pid tty_nr tpgid);
  write_file (Filename.concat dir "environ") environ;
  if exe <> "" then (try Unix.symlink exe (Filename.concat dir "exe") with _ -> ())

let graphical = "DISPLAY=:0\000HOME=/home/user\000SHELL=/bin/bash\000"

let () =
  (* ---------------- macOS: lsappinfo / osascript ---------------- *)
  let apps = parse_lsappinfo lsappinfo_fixture in
  check "lsappinfo: keeps the 4 Foreground apps" (List.length apps = 4);
  check "lsappinfo: names kept in order"
    (List.map (fun a -> a.name) apps
    = [ "Finder"; "Firefox Developer Edition"; "Safari"; "Weird \"Quote\" App" ]);
  check "lsappinfo: pids extracted"
    (List.map (fun a -> a.pid) apps = [ 624; 89719; 88043; 5 ]);
  check "lsappinfo: bundle path extracted"
    (match (List.hd apps).bundle with
     | Some b -> b = "/System/Library/CoreServices/Finder.app"
     | None -> false);
  check "lsappinfo: drops BackgroundOnly"
    (not (List.exists (fun a -> a.pid = 607) apps));
  check "lsappinfo: escaped quotes unescaped"
    (List.exists (fun a -> a.name = "Weird \"Quote\" App") apps);

  check "osascript: parse pid<TAB>name lines"
    (parse_osascript osascript_fixture
    = [ mk "Finder" 624; mk "Safari" 88043; mk "firefox" 89719 ]);
  check "empty inputs parse to []"
    (parse_lsappinfo "" = [] && parse_osascript "" = [] && parse_wmctrl "" = []
    && parse_tasklist "" = []);

  (* ---------------- Linux: /proc ---------------- *)
  let stat =
    "1234 (Web Content) S 1000 1234 1234 0 -1 4194304 1234 567 0 0 0 0 0 20 0 \
     1 0 12345 67890123 1234 18446744073709551615 1 1 0 0 0 0 0 0 0 0 0 0 17 \
     3 0 0 0 0 0 0 0 0 0 0 0 0 0\n"
  in
  (match parse_proc_stat stat with
   | Some i ->
     check "proc stat: pid/ppid/pgrp/session/tty/tpgid parsed"
       (i.p_pid = 1234 && i.p_ppid = 1000 && i.p_pgrp = 1234 && i.p_session = 1234
       && i.p_tty_nr = 0 && i.p_tpgid = -1);
     check "proc stat: comm with a space kept" (i.p_comm = "Web Content")
   | None -> check "proc stat: parses a real line" false);
  (match parse_proc_stat "42 (foo (bar)) S 1 42 42 34816 34816 0 0 0\n" with
   | Some i ->
     check "proc stat: comm containing parentheses kept" (i.p_comm = "foo (bar)");
     check "proc stat: controlling tty read" (i.p_tty_nr = 34816)
   | None -> check "proc stat: comm with parentheses parses" false);
  check "proc stat: junk -> None"
    (parse_proc_stat "not a stat line" = None
    && parse_proc_stat "" = None
    && parse_proc_stat "12 (x) S 1 2\n" = None);

  check "graphical env: DISPLAY counts"
    (has_graphical_env graphical && has_graphical_env "WAYLAND_DISPLAY=wayland-0\000");
  check "graphical env: empty DISPLAY does not count"
    (not (has_graphical_env "DISPLAY=\000HOME=/root\000"));
  check "graphical env: no display at all"
    (not (has_graphical_env "HOME=/root\000PATH=/usr/bin\000"));

  let desktop =
    "[Desktop Entry]\n\
     Type=Application\n\
     Name=Firefox\n\
     Name[de]=Feuerfuchs\n\
     Exec=/usr/lib/firefox/firefox %u\n\
     Icon=firefox\n\
     \n\
     [Desktop Action NewWindow]\n\
     Name=New Window\n\
     Exec=/usr/lib/firefox/firefox --new-window\n"
  in
  let kv = parse_desktop_entry desktop in
  check "desktop entry: Name read from the Desktop Entry group"
    (List.assoc_opt "Name" kv = Some "Firefox");
  check "desktop entry: localized Name does not win"
    (List.assoc_opt "Name[de]" kv = Some "Feuerfuchs");
  check "desktop entry: other groups ignored"
    (List.assoc_opt "Exec" kv = Some "/usr/lib/firefox/firefox %u");
  check "desktop exec: field codes and arguments dropped"
    (desktop_exec_basename "/usr/lib/firefox/firefox %u" = Some "firefox"
    && desktop_exec_basename "\"/opt/My App/bin/app\" --flag" = Some "app");
  check "desktop exec: env prefix skipped"
    (desktop_exec_basename "env BAMF_DESKTOP_FILE_HINT=x /usr/bin/gimp %U"
    = Some "gimp");
  check "desktop exec: wrappers are not application binaries"
    (desktop_exec_basename "/usr/bin/flatpak run org.mozilla.firefox" = None
    && desktop_exec_basename "/usr/bin/snap run spotify" = None
    && desktop_exec_basename "" = None);

  check "linux infrastructure recognised"
    (is_linux_infrastructure "gnome-shell"
    && is_linux_infrastructure "Xorg"
    && is_linux_infrastructure "xdg-desktop-portal-gtk"
    && is_linux_infrastructure "gsd-power"
    && is_linux_infrastructure "dbus-daemon");
  check "real applications are not infrastructure"
    (not (is_linux_infrastructure "firefox")
    && not (is_linux_infrastructure "gnome-terminal-server")
    && not (is_linux_infrastructure "nautilus")
    && not (is_linux_infrastructure "evolution"));

  (* ---------------- Linux: wmctrl ---------------- *)
  let wm = parse_wmctrl wmctrl_fixture in
  check "wmctrl: one entry per pid (windows deduplicated)"
    (List.map (fun a -> a.pid) wm = [ 3041; 5123; 7001; 6001 ]);
  check "wmctrl: name taken from the window class"
    (List.map (fun a -> a.name) wm
    = [ "Firefox"; "Gnome-terminal"; "Gnome-calendar"; "An Untitled Window" ]);
  check "wmctrl: the client machine is not part of the name"
    (not (List.exists (fun a -> has_sub a.name host) wm));
  check "wmctrl: bogus lines ignored" (parse_wmctrl "hello\n\n" = []);

  (* ---------------- Windows: tasklist ---------------- *)
  let tl = parse_tasklist tasklist_fixture in
  check "tasklist: only windowed processes are listed"
    (List.map (fun a -> a.pid) tl = [ 1234; 4321; 777 ]);
  check "tasklist: .exe dropped from the name"
    (List.map (fun a -> a.name) tl = [ "chrome"; "notepad"; "weird \"quoted\"" ]);
  check "tasklist: CSV quotes and commas handled"
    (parse_csv_line "\"a,b\",\"c\"\"d\",e" = [ "a,b"; "c\"d"; "e" ]);
  check "tasklist: services (N/A window title) are dropped"
    (not (List.exists (fun a -> a.pid = 660 || a.pid = 1235) tl));

  (* ---------------- name matching ---------------- *)
  let sample = parse_lsappinfo lsappinfo_fixture in
  (match match_name sample "safari" with
   | Unique a -> check "match: case-insensitive exact" (a.pid = 88043)
   | _ -> check "match: case-insensitive exact" false);
  (match match_name sample "Safari.app" with
   | Unique a -> check "match: trailing .app ignored" (a.pid = 88043)
   | _ -> check "match: trailing .app ignored" false);
  (match match_name sample "  finder  " with
   | Unique a -> check "match: surrounding whitespace trimmed" (a.pid = 624)
   | _ -> check "match: surrounding whitespace trimmed" false);
  (match match_name sample "firefox" with
   | Unique a ->
     check "match: unique substring accepted" (a.name = "Firefox Developer Edition")
   | _ -> check "match: unique substring accepted" false);
  (match match_name sample "chrome" with
   | None_found -> check "match: no running app -> None_found" true
   | _ -> check "match: no running app -> None_found" false);
  (match match_name [ mk "Safari" 1; mk "Safari Technology Preview" 2 ] "saf" with
   | Ambiguous _ -> check "match: ambiguous substring" true
   | _ -> check "match: ambiguous substring" false);
  (match match_name [ mk "Notes" 1; mk "StickNotes" 2 ] "notes" with
   | Unique a when a.name = "Notes" ->
     check "match: exact preferred over substring" true
   | _ -> check "match: exact preferred over substring" false);
  (match find_pid sample 88043 with
   | Some a -> check "find_pid: by pid" (a.name = "Safari")
   | None -> check "find_pid: by pid" false);
  check "find_pid: missing pid -> None" (find_pid sample 99999 = None);

  (* ---------------- protected system applications ---------------- *)
  check "normalize_app_name: suffixes, spaces and case"
    (normalize_app_name "Finder.app" = "finder"
    && normalize_app_name "Control Center" = "controlcenter"
    && normalize_app_name "Explorer.EXE" = "explorer"
    && normalize_app_name "org.gnome.Nautilus.desktop" = "org.gnome.nautilus");
  (match platform () with
   | Macos ->
     check "protected: Finder is protected"
       (is_protected_name "Finder" && is_protected_name "finder.app"
       && is_protected_name "Control Center");
     check "protected: real apps are not protected"
       (not (is_protected_name "Safari") && not (is_protected_name "Firefox"))
   | Linux ->
     check "protected: the session shell and WM are protected"
       (is_protected_name "gnome-shell" && is_protected_name "Xorg"
       && is_protected_name "systemd");
     check "protected: real apps are not protected"
       (not (is_protected_name "firefox") && not (is_protected_name "nautilus"))
   | Windows ->
     check "protected: the shell and session processes are protected"
       (is_protected_name "explorer" && is_protected_name "Explorer.exe"
       && is_protected_name "csrss" && is_protected_name "dwm");
     check "protected: real apps are not protected"
       (not (is_protected_name "chrome") && not (is_protected_name "notepad"))
   | Other _ -> skip "protected names" "unsupported platform");

  (* ---------------- interactive index lists ---------------- *)
  check "parse_index_list: single number" (parse_index_list "3" = Some [ 3 ]);
  check "parse_index_list: comma-separated, spaces tolerated"
    (parse_index_list "1, 3,5" = Some [ 1; 3; 5 ]);
  check "parse_index_list: order preserved" (parse_index_list "3,1" = Some [ 3; 1 ]);
  check "parse_index_list: empty / blank -> None"
    (parse_index_list "" = None && parse_index_list "   " = None);
  check "parse_index_list: empty tokens -> None"
    (parse_index_list "1," = None && parse_index_list ",1" = None
    && parse_index_list "1,,2" = None);
  check "parse_index_list: non-numeric token -> None"
    (parse_index_list "1,x" = None && parse_index_list "abc" = None);
  check "parse_index_list: zero / negatives rejected"
    (parse_index_list "0" = None && parse_index_list "-1,2" = None);

  (* ---------------- the /proc backend, end to end ---------------- *)
  with_temp_dir (fun tmp ->
      let root = Filename.concat tmp "proc" in
      let apps_dir = Filename.concat tmp "applications" in
      mkdir_p root;
      mkdir_p apps_dir;
      write_file
        (Filename.concat apps_dir "firefox.desktop")
        "[Desktop Entry]\nType=Application\nName=Firefox\n\
         Exec=/usr/lib/firefox/firefox %u\n";
      (* 100: a real application, group leader, no controlling terminal *)
      proc_entry root ~pid:100 ~comm:"firefox" ~ppid:1 ~pgrp:100 ~tty_nr:0
        ~environ:graphical ~exe:"/usr/lib/firefox/firefox";
      (* 101: same, but not in a graphical session *)
      proc_entry root ~pid:101 ~comm:"make" ~ppid:1 ~pgrp:101 ~tty_nr:0
        ~environ:"HOME=/home/user\000" ~exe:"/usr/bin/make";
      (* 102: console program the terminal is running in the foreground *)
      proc_entry root ~pid:102 ~comm:"vim" ~ppid:200 ~pgrp:200 ~tty_nr:34816
        ~environ:graphical ~exe:"/usr/bin/vim";
      (* 105: an interactive shell in a terminal *)
      proc_entry root ~pid:105 ~comm:"bash" ~ppid:200 ~pgrp:105 ~tty_nr:34816
        ~environ:graphical ~exe:"/usr/bin/bash";
      (* 106: an application started from a terminal in the background *)
      proc_entry ~tpgid:200 root ~pid:106 ~comm:"gimp" ~ppid:200 ~pgrp:106
        ~tty_nr:34816 ~environ:graphical ~exe:"/usr/bin/gimp";
      (* 103: session infrastructure *)
      proc_entry root ~pid:103 ~comm:"gnome-shell" ~ppid:1 ~pgrp:103 ~tty_nr:0
        ~environ:graphical ~exe:"/usr/bin/gnome-shell";
      (* 104: no .desktop entry, no /proc/<pid>/exe -> comm is used *)
      proc_entry root ~pid:104 ~comm:"inkscape" ~ppid:1 ~pgrp:104 ~tty_nr:0
        ~environ:graphical ~exe:"";
      write_file (Filename.concat root "stat") "not a pid\n";
      let listed =
        match list_apps_procfs ~proc_root:root ~desktop_dirs:[ apps_dir ] with
        | Ok l -> l
        | Error e ->
          check ("list_apps_procfs failed: " ^ e) false;
          []
      in
      check "procfs: only desktop applications are listed"
        (List.map (fun a -> a.pid) listed = [ 100; 106; 104 ]);
      check "procfs: a console program is not an application"
        (not (List.exists (fun a -> a.pid = 102) listed));
      check "procfs: an interactive shell is not an application"
        (not (List.exists (fun a -> a.pid = 105) listed));
      check "procfs: an application started from a terminal is listed"
        (List.exists (fun a -> a.pid = 106 && a.name = "gimp") listed);
      check "procfs: name comes from the .desktop entry"
        (match listed with
         | a :: _ ->
           a.name = "Firefox"
           && a.bundle = Some (Filename.concat apps_dir "firefox.desktop")
         | [] -> false);
      check "procfs: fallback name is the executable basename"
        (List.exists (fun a -> a.pid = 104 && a.name = "inkscape") listed);
      check "procfs: a missing proc root is an error, not a crash"
        (match list_apps_procfs ~proc_root:(Filename.concat tmp "nope") ~desktop_dirs:[] with
         | Error _ -> true
         | Ok _ -> false));

  (* ---------------- process-tree helpers ----------------
     These need ps(1), which some sandboxes do not allow. When it is
     unavailable the checks are skipped instead of failing. *)
  let ps_works =
    match run_capture [| "ps"; "-o"; "pid="; "-p"; string_of_int (Unix.getpid ()) |] with
    | Ok s -> String.trim s <> ""
    | Error _ -> false
  in
  if not ps_works then begin
    skip "parent_pid_of / ancestor_pids / own_process_group" "ps(1) unavailable"
  end
  else begin
    (match parent_pid_of (Unix.getpid ()) with
     | Some parent when parent > 0 ->
       let chain = ancestor_pids ~pid:(Unix.getpid ()) in
       check "ancestor_pids: nearest ancestor is our parent"
         (match chain with p :: _ -> p = parent | [] -> false);
       check "ancestor_pids: successive pids are parent/child"
         (let rec linked = function
           | [] | [ _ ] -> true
           | a :: (b :: _ as rest) -> parent_pid_of a = Some b && linked rest
         in
         linked chain);
       check "ancestor_pids: no duplicates"
         (let rec nodup = function
           | [] -> true
           | a :: rest -> (not (List.mem a rest)) && nodup rest
         in
         nodup chain);
       check "ancestor_pids: stops before launchd (pid 1)"
         (List.for_all (fun p -> p > 1) chain)
     | _ -> check "parent_pid_of: our parent exists" false);
    check "parent_pid_of: gone pid -> None" (parent_pid_of 999999 = None);
    check "ancestor_pids: dead seed -> []" (ancestor_pids ~pid:999999 = []);
    check "own_process_group: reports a live group"
      (match own_process_group () with Some pg -> pg > 0 | None -> false);
    check "executable_of_pid: reports our own binary"
      (match executable_of_pid (Unix.getpid ()) with Some b -> b <> "" | None -> false)
  end;

  (* "Self process" guard: force_quit_pid must never signal fq's own pid.
     This must return an error (not kill the test process!). *)
  check "force_quit_pid: refuses fq's own pid"
    (match force_quit_pid (Unix.getpid ()) with Error _ -> true | Ok _ -> false);

  if !failures > 0 then begin
    Printf.printf "%d/%d checks failed\n%!" !failures !checks;
    exit 1
  end
  else Printf.printf "all %d checks passed\n%!" !checks
