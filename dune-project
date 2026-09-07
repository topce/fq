(lang dune 3.24)

(name fq)

(version 0.1.0)

(generate_opam_files true)

(source
 (github topce/fq))

(authors "FQ contributors")

(maintainers "FQ contributors")

(license MIT)

(package
 (name fq)
 (synopsis "Force-quit macOS applications from the command line, like the Force Quit dialog")
 (description
  "fq lists the running GUI applications on macOS and force-quits the chosen one with SIGKILL, mirroring the behaviour of the system Force Quit dialog (Option-Command-Escape). It enumerates applications with lsappinfo(1), so no Automation/Accessibility permissions are needed, and falls back to System Events via osascript. Multi-process applications (browsers, etc.) are taken down completely by killing their process group.")
 (depends
  ocaml)
 (tags
  ("macos"
   "processes"
   "tools")))
