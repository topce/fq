# Releasing fq

How a release is cut, published to every channel, verified, and rolled back if
it turns out to be a bad one. The automation lives in `.github/workflows/`; the
channel manifests in `packaging/`.

- [What a release produces](#what-a-release-produces)
- [One-time setup](#one-time-setup)
- [Cutting a release](#cutting-a-release)
- [Publishing to each channel](#publishing-to-each-channel)
- [Staged rollout (canary)](#staged-rollout-canary)
- [Post-release verification](#post-release-verification)
- [Rollback](#rollback)
- [Monitoring and upkeep](#monitoring-and-upkeep)
- [Pre-launch checklist](#pre-launch-checklist)
- [Known gaps before announcing widely](#known-gaps-before-announcing-widely)

## What a release produces

Pushing a `vX.Y.Z` tag runs `.github/workflows/release.yml`, which builds and
tests on five targets, packages each one, verifies the *archive* (not the build
tree), attests its provenance and publishes a GitHub release with:

| Artifact | Built on | Notes |
| --- | --- | --- |
| `fq-X.Y.Z-linux-x86_64.tar.gz` | `ubuntu-22.04` | glibc ≥ 2.35: Ubuntu 22.04+, Debian 12+, RHEL 9+, Fedora 35+ |
| `fq-X.Y.Z-linux-x86_64-static.tar.gz` | `ubuntu-22.04`, musl | fully static: Alpine, NixOS, old glibc. Best effort (`continue-on-error`) |
| `fq-X.Y.Z-macos-x86_64.tar.gz` | `macos-13` | Intel |
| `fq-X.Y.Z-macos-arm64.tar.gz` | `macos-14` | Apple silicon |
| `fq-X.Y.Z-windows-x86_64.zip` | `windows-latest` | native PE, no runtime dependencies (Windows on ARM runs the x64 build) |
| `SHA256SUMS` | — | every archive, used by the Scoop/WinGet/AUR manifests |

Every archive is a directory with the binary, `README.md`, `LICENSE` and
`CHANGELOG.md`. The Windows ARM64 and Linux ARM64 targets are not built:
`ocaml/setup-ocaml` has no Windows ARM64 support, and the Linux ARM64 runner is
not worth the CI minutes until someone asks for it (adding `ubuntu-24.04-arm`
to the matrix is a one-line change).

Each artifact carries a signed build-provenance attestation, so anyone can run:

```sh
gh attestation verify fq-0.4.0-windows-x86_64.zip --repo topce/fq
```

## One-time setup

| Channel | What has to exist once |
| --- | --- |
| GitHub Releases | nothing — the workflow uses the built-in `GITHUB_TOKEN` |
| Homebrew | the tap `topce/homebrew-fq` (exists) |
| opam | an `opam-publish` token (`~/.opam/config` + a GitHub token) |
| Scoop | a bucket repository, e.g. `topce/scoop-bucket`, with a `bucket/` directory and a `README.md` |
| WinGet | a fork of `microsoft/winget-pkgs` and a **classic** PAT with the `public_repo` scope, stored as the repository secret `WINGET_TOKEN`; plus one manual first submission (below) |
| AUR | an AUR account with an SSH key registered |

Nothing in the repository is secret and no credential is needed to *build* a
release.

## Cutting a release

1. **Bump the version in the three places that must agree** — the release job
   refuses to publish when they disagree with the tag:

   ```sh
   $EDITOR dune-project              # (version 0.4.0)
   $EDITOR lib/fq.ml                 # let version = "0.4.0"
   $EDITOR CHANGELOG.md              # ## [0.4.0] - YYYY-MM-DD
   dune build                        # regenerates fq.opam from dune-project
   git commit -am "Release v0.4.0"
   ```

2. **Run the full suite locally** (all three platforms in CI too):

   ```sh
   dune build && dune runtest
   ```

3. **Push a tag.** Use a suffix first if the release is at all risky — a tag
   with a `-` in it publishes a *prerelease*, which is the canary stage:

   ```sh
   git push origin main
   git tag v0.4.0-rc.1 && git push origin v0.4.0-rc.1   # canary
   git tag v0.4.0     && git push origin v0.4.0         # full release
   ```

4. **Watch the workflow** (`gh run watch`) and read the job summary: it lists
   every artifact with its sha256. CI (`ci.yml`) must be green on `main` first.

5. **Render the channel manifests** from the published checksums:

   ```sh
   gh release download v0.4.0 -p SHA256SUMS
   source_sha=$(curl -sL https://github.com/topce/fq/archive/refs/tags/v0.4.0.tar.gz | shasum -a 256 | cut -d' ' -f1)
   packaging/render.sh 0.4.0 SHA256SUMS /tmp/fq-0.4.0 "$source_sha"
   ```

   Then publish as described below. Rendered files are inputs to a review, not
   something to commit here.

## Publishing to each channel

### Linux

**1. Release tarball (already done by the workflow).** This is the primary
Linux channel and needs no third party:

```sh
curl -LO https://github.com/topce/fq/releases/download/v0.4.0/fq-0.4.0-linux-x86_64.tar.gz
sha256sum -c SHA256SUMS --ignore-missing
tar -xzf fq-0.4.0-linux-x86_64.tar.gz && sudo install -m755 fq-0.4.0-linux-x86_64/fq /usr/local/bin/fq
```

**2. Homebrew (Linuxbrew) and macOS** — the tap builds from source with
`ocaml` + `dune`, so the same formula serves both platforms. Copy the rendered
formula into the tap and push:

```sh
cp /tmp/fq-0.4.0/homebrew/fq.rb ../homebrew-fq/Formula/fq.rb
git -C ../homebrew-fq commit -am "fq 0.4.0" && git -C ../homebrew-fq push
brew update && brew install topce/fq/fq
```

`brew bump-formula-pr --url=... --sha256=... topce/fq/fq` does the same thing
through a PR. The formula in the tap still says "macOS" and tests for 0.3.1 —
the rendered one is platform-neutral, so Linuxbrew users can install it too.

**3. AUR (Arch)** — push the rendered `PKGBUILD` with a generated `.SRCINFO`:

```sh
git clone ssh://aur@aur.archlinux.org/fq.git && cd fq
cp /tmp/fq-0.4.0/aur/PKGBUILD .
makepkg --printsrcinfo > .SRCINFO
git add PKGBUILD .SRCINFO && git commit -m "fq 0.4.0" && git push
```

A `fq-bin` package using the release tarball is a reasonable alternative when
users should not need an OCaml toolchain.

**4. .deb / .rpm (optional)** — `nfpm` turns the Linux tarball into native
packages; attach them to the same release:

```sh
tar -xzf fq-0.4.0-linux-x86_64.tar.gz
nfpm package -f /tmp/fq-0.4.0/nfpm.yaml -p deb -t fq_0.4.0_amd64.deb
nfpm package -f /tmp/fq-0.4.0/nfpm.yaml -p rpm -t fq-0.4.0.x86_64.rpm
gh release upload v0.4.0 fq_0.4.0_amd64.deb fq-0.4.0.x86_64.rpm
```

A hosted apt/dnf repository (Cloudsmith, Gemfury, or a GitHub Pages `dists/`
tree) is the next step if the packages get traction; until then the release
page is the distribution point.

**5. opam** (source installs for macOS and Linux — the natural channel for
OCaml users):

```sh
opam publish --tag v0.4.0 https://github.com/topce/fq
```

That opens a PR against `opam-repository`; once merged, `opam install fq`
works. Windows users are not served by opam-repository (its CI does not test
the native Windows port), which is what the zip, Scoop and WinGet are for.

**Do not ship fq as a Snap or Flatpak.** Both sandbox the application: it would
see only its own confined processes and could not enumerate or kill anything
outside the sandbox, so the tool would list an empty world and quit exactly
nothing. A Docker image has the same problem unless run with `--pid=host`, and
even then it needs a matching `/proc`. Distro packages, the tarball and
Homebrew are the honest options.

### Windows

**1. Release zip (already done by the workflow).** Unblock and run:

```powershell
Expand-Archive fq-0.4.0-windows-x86_64.zip -DestinationPath .
.\fq-0.4.0-windows-x86_64\fq.exe --version
```

**2. Scoop** — a bucket repository makes the tool installable and updatable:

```sh
cp /tmp/fq-0.4.0/scoop/fq.json ../scoop-bucket/bucket/fq.json
git -C ../scoop-bucket add bucket/fq.json && git -C ../scoop-bucket commit -m "fq 0.4.0" && git -C ../scoop-bucket push
```

Users then run `scoop bucket add topce https://github.com/topce/scoop-bucket`
once and `scoop install topce/fq` afterwards. The manifest carries `checkver`
and `autoupdate`, so `scoop update` picks new releases up automatically, reading
the hash straight out of our `SHA256SUMS`. (`ScoopInstaller/GithubActions` can
automate the bucket commit.) The main `Extras` bucket has notability criteria —
propose it there only if the project gets that far.

**3. WinGet** — the first version must be submitted by hand; every later one is
automated by `.github/workflows/publish-winget.yml`:

```sh
# first submission, from a fork of microsoft/winget-pkgs
mkdir -p ~/winget-pkgs/manifests/t/Topce/Fq/0.4.0
cp /tmp/fq-0.4.0/winget/Topce.Fq*.yaml ~/winget-pkgs/manifests/t/Topce/Fq/0.4.0/
# on Windows: winget validate --manifest <dir>   (or: wingetcreate validate <dir>)
cd ~/winget-pkgs && git checkout -b topce-fq-0.4.0 && git add manifests/t/Topce && git commit -m "Add Topce.Fq 0.4.0" && gh pr create --repo microsoft/winget-pkgs
```

After that PR is merged, set the `WINGET_TOKEN` secret (classic PAT,
`public_repo` scope) and the workflow opens the update PR for each release. The
manifests install fq as a **portable** package: WinGet unpacks the zip and puts
`fq.exe` on `PATH` under the alias `fq`.

**4. Optional** — Chocolatey (needs a community account, a moderation queue and
a `chocolateyinstall.ps1`), or an MSYS2 package for people already in that
ecosystem. Neither is required: the zip, Scoop and WinGet cover the platform.

## Staged rollout (canary)

A CLI that kills processes has one catastrophic failure mode — killing the
wrong thing — and releases cannot be un-downloaded, so releases go out in two
stages:

1. **Canary** — tag `v0.4.0-rc.1`. The workflow publishes it as a prerelease:
   no channel points at it (WinGet's publish job only fires for full releases),
   so it is visible only to people who look for it.
2. **Verify on real machines** (see below) — at least one real Linux desktop
   session (X11 *and* Wayland if possible), one Windows 11 machine, one Mac.
3. **Promote** — either edit the release and untick *prerelease*, or push the
   final `v0.4.0` tag. Promotion is what triggers the WinGet submission.
4. **Announce and publish the channels** — Homebrew, Scoop, AUR, opam. Use the
   same rendered manifests; only the version string changes.
5. **Watch the first 24 hours** — issues, download counts, and any report of a
   wrong application being killed (that one is a stop-ship).

## Post-release verification

Run these against the *downloaded artifacts*, on real machines, before
promoting anything:

```sh
sha256sum -c SHA256SUMS                     # Linux/macOS
gh attestation verify fq-0.4.0-<target>.tar.gz --repo topce/fq
```

| Platform | Checks |
| --- | --- |
| Linux | `fq --list` lists your desktop apps and not shells; `fq` picker kills the chosen app only; `fq --others -y -s` keeps the terminal alive and suspends; `fq -b wmctrl --list` agrees on X11 |
| Windows | `fq --list` shows windowed apps; `fq -y notepad` closes Notepad with unsaved text; `fq --others -y` does **not** close Windows Terminal; `fq --pid <unused> -y` exits 0 |
| macOS | `fq --list` matches the Force Quit dialog (⌥⌘⎋); `fq -y Safari` behaves like the dialog; `brew test topce/fq/fq` passes |

## Rollback

Nothing here needs a redeploy: the release page and the channel manifests are
the state.

| Situation | Action | Time |
| --- | --- | --- |
| Bad artifact, channel not yet updated | `gh release delete v0.4.0 --yes --cleanup-tag`, fix, re-tag | minutes |
| Bad release already announced | `gh release edit v0.4.0 --prerelease` (stops WinGet/Scoop autoupdate picking it up), then `gh release delete-asset v0.4.0 <file>` and publish a fixed patch release | minutes |
| Bad Homebrew formula | revert the tap commit (`git -C ../homebrew-fq revert HEAD && git push`) | minutes |
| Bad Scoop manifest | revert the bucket commit; users who already installed keep the binary but `scoop update` will not move them further | minutes |
| Bad WinGet manifest | open a PR removing the version directory (or supersede it with a patch release — WinGet keeps history) | days (moderation) |
| Bad AUR package | `git revert && git push`; deleting the package outright also removes it for new users | minutes |
| Bad opam release | opam-repository has no yank: publish a patch release, or a PR marking the version `available: false` | days |
| Wrong application killed (any version) | treat as a stop-ship: mark the release prerelease, open a pinned issue with the reproduction, and do not publish the channels until a fix is out | immediately |

Rollback never restores users who already downloaded the bad artifact — that is
what the canary stage is for.

## Monitoring and upkeep

* **CI** — `ci.yml` runs on every push and weekly on a schedule, so runner and
  toolchain drift shows up before a release, not during one.
* **Downloads** — `gh release view v0.4.0 --json assets --jq '.assets[] | "\(.name) \(.downloadCount)"'`
  gives a rough adoption signal per platform, which is also the hint about which
  channel deserves automation next.
* **Issues** — label anything about the wrong process being killed as
  `safety`, and treat an open `safety` issue as a release freeze until fixed.
* **Channel drift** — after each release, check that Scoop, WinGet, AUR and the
  tap show the new version; the `autoupdate` blocks in the Scoop manifest and
  the WinGet workflow are the only moving parts.
* **Dependencies** — Dependabot (`.github/dependabot.yml`) keeps the actions
  current; the project itself has no third-party OCaml dependencies, so there
  is no lockfile to audit.

## Pre-launch checklist

Adapted to a CLI with no server side; the web-specific items (CSP, CORS, Core
Web Vitals, database migrations) do not apply.

- [ ] `dune build` and `dune runtest` green locally, and `ci.yml` green on the
      tagged commit for all three platforms
- [ ] Version agrees in `dune-project`, `lib/fq.ml`, `CHANGELOG.md` and the tag
      (the release job enforces this)
- [ ] `CHANGELOG.md` describes every user-visible change, including behaviour
      changes and fixes
- [ ] README install instructions match what actually exists for this version
- [ ] No secrets, tokens or machine-specific paths in the tree
- [ ] `fq --help` on each platform shows that platform's backends, protected
      applications and sleep command
- [ ] Rollback plan understood (table above) and the canary tag used for
      anything risky
- [ ] Channel manifests rendered from the published `SHA256SUMS` — never
      hand-edited hashes
- [ ] Post-release verification table run on at least one real machine per
      platform before promoting the canary

## Known gaps before announcing widely

* **Windows binaries are unsigned.** SmartScreen will show "Windows protected
  your PC" on first run, and security software may flag a process-killing tool
  as a potentially unwanted application. Fix by signing with Azure Trusted
  Signing or [SignPath.io](https://signpath.io) (free for OSS), and by
  submitting a false-positive report to Microsoft if Defender complains. Until
  then the release notes should say the binary is unsigned and give the
  sha256 so users can verify.
* **macOS binaries are unsigned and unnotarized.** The Homebrew formula builds
  from source, so its users never see a quarantine prompt; users who download
  the tarball in a browser may need `xattr -d com.apple.quarantine fq`.
* **No Linux ARM64 build**, and no Windows ARM64 build (upstream toolchain
  limitation). Windows on ARM runs the x64 binary through emulation.
* **Linux listing is a heuristic.** The README says what it includes and what
  it hides; a user who cannot find an application they launched from a terminal
  should be pointed at `fq --pid` or `-b wmctrl`.
