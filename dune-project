(lang dune 3.24)

(name fq)

(version 0.4.0)

(generate_opam_files true)

(source
 (github topce/fq))

(authors "FQ contributors")

(maintainers "FQ contributors")

(license MIT)

(package
 (name fq)
 (synopsis
  "Force-quit applications from the command line, like the Force Quit dialog")
 (description
  "fq lists the running GUI applications and force-quits the chosen one, with no chance to save work and helper processes taken down with the app. The command line is the same on macOS, Linux and Windows; the implementation is not: macOS enumerates applications with lsappinfo(1) (the apps the Force Quit dialog shows) and kills the process group, Linux enumerates the applications of the graphical session from /proc (or wmctrl) and kills the process group or the process tree, and Windows enumerates windowed processes with tasklist(1) and kills them with taskkill /T /F. -s/--sleep puts the machine to sleep afterwards (pmset, systemctl, SetSuspendState).")
 (depends
  (ocaml
   (>= 5.0)))
 (tags
  ("macos"
   "linux"
   "windows"
   "processes"
   "tools")))
