(* Unit tests for the Fq library: lsappinfo / osascript parsers and name
   matching. Run with: dune runtest *)

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

let mk name pid = { name; pid; bundle = None }

let () =
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
  check "lsappinfo: drops BackgroundOnly" (not (List.exists (fun a -> a.pid = 607) apps));
  check "lsappinfo: escaped quotes unescaped"
    (List.exists (fun a -> a.name = "Weird \"Quote\" App") apps);

  check "osascript: parse pid<TAB>name lines"
    (parse_osascript osascript_fixture
    = [ mk "Finder" 624; mk "Safari" 88043; mk "firefox" 89719 ]);
  check "empty inputs parse to []"
    (parse_lsappinfo "" = [] && parse_osascript "" = []);

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

  (* Process-tree helpers: self-referential smoke tests using live ps(1) on
     our own pid — a process is always its parent's child, so these are
     deterministic without hard-coding any PID. *)
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

  if !failures > 0 then begin
    Printf.printf "%d/%d checks failed\n%!" !failures !checks;
    exit 1
  end
  else Printf.printf "all %d checks passed\n%!" !checks
