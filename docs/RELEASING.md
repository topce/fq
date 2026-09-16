# Releasing fq

How a release is cut, published and rolled back. **There is no CI/CD**: every
artifact and every channel publication below is a command a person runs and
reviews. The package managers build fq from source, so a release needs nothing
but a tag and a changelog — prebuilt binaries are optional and hand-made.

- [What a release is](#what-a-release-is)
- [Before you tag](#before-you-tag)
- [Tagging](#tagging)
- [Package managers (the primary channels)](#package-managers-the-primary-channels)
- [Prebuilt binaries (optional, hand-made)](#prebuilt-binaries-optional-hand-made)
- [Windows package managers (need a Windows build)](#windows-package-managers-need-a-windows-build)
- [Staged rollout](#staged-rollout)
- [Verification](#verification)
- [Rollback](#rollback)
- [Monitoring and upkeep](#monitoring-and-upkeep)
- [Known gaps](#known-gaps)

## What a release is

1. A version that agrees in four places: `dune-project`, `lib/fq.ml`,
   `CHANGELOG.md` and the git tag.
2. An annotated tag `vX.Y.Z` on `main`.
3. Channel updates — Homebrew (macOS and Linuxbrew), AUR, opam. These build
   from the tag's source tarball.
4. Optionally, prebuilt archives attached to a GitHub release, and the Scoop /
   WinGet manifests that point at them.

Nothing is published automatically, so a mistake is fixed by not publishing (or
by reverting a channel commit), never by rolling back a pipeline.

## Before you tag

- [ ] `dune build && dune runtest` is green (59 unit checks, 31 sleep checks,
      21 platform checks on macOS/Linux; Windows runs the unit tests).
- [ ] The suite has been run on every platform you intend to claim support for:
      macOS and Linux locally, Windows on a Windows machine or VM
      (`dune runtest` there runs the unit tests, and
      `_build\default\bin\main.exe --list` exercises the real `tasklist`
      backend).
- [ ] `CHANGELOG.md` describes every user-visible change, including behaviour
      changes and fixes.
- [ ] The version is bumped in `dune-project` (then `dune build` regenerates
      `fq.opam`), `lib/fq.ml` and `CHANGELOG.md`.
- [ ] `README.md` install instructions match what actually exists for this
      version.
- [ ] No secrets, tokens or machine-specific paths in the tree
      (`git status`, `git diff --cached`).
- [ ] The rollback table below has been read, and anything risky is going out
      as a prerelease first.

The version gate is manual now, so check it explicitly — a release whose
`--version` lies is worse than no release:

```sh
tag=v0.4.0
printf 'dune-project: %s\nlib/fq.ml:    %s\nCHANGELOG:    %s\n' \
  "$(sed -n 's/^(version \(.*\))$/\1/p' dune-project)" \
  "$(sed -n 's/^let version = "\(.*\)"$/\1/p' lib/fq.ml)" \
  "$(sed -n 's/^## \[\([^]]*\)\].*/\1/p' CHANGELOG.md | head -1)"
```

## Tagging

```sh
git commit -am "Release v0.4.0"      # if the version bump is not committed yet
git tag -a v0.4.0 -m "fq 0.4.0"
git push origin main
git push origin v0.4.0
```

Then publish the GitHub release page (source only, unless you built artifacts):

```sh
gh release create v0.4.0 --title "fq 0.4.0" --generate-notes
# or, for a canary: --prerelease --latest=false
```

A tag is cheap to delete **as long as no channel points at it yet**:

```sh
git push --delete origin v0.4.0 && git tag -d v0.4.0
```

## Package managers (the primary channels)

All three build from the source tarball of the tag, so they work on any
platform the tool supports and need no uploaded binaries.

### Homebrew — macOS and Linuxbrew

```sh
# sha256 of the tag tarball
source_sha=$(curl -sL https://github.com/topce/fq/archive/refs/tags/v0.4.0.tar.gz \
             | shasum -a 256 | cut -d' ' -f1)

# render the formula from the template and publish it in the tap
packaging/render.sh 0.4.0 /dev/null /tmp/fq-0.4.0 "$source_sha" || true   # see note
cp /tmp/fq-0.4.0/homebrew/fq.rb "$(brew --repo topce/fq)/Formula/fq.rb"
git -C "$(brew --repo topce/fq)" commit -am "fq 0.4.0" && git -C "$(brew --repo topce/fq)" push
```

`packaging/render.sh` needs a `SHA256SUMS` file because it renders every
manifest; to fill in only the Homebrew formula, substitute the placeholder
directly:

```sh
sed -e "s|@VERSION@|0.4.0|g" \
    -e "s|@SHA256_SOURCE_TARBALL@|$source_sha|g" \
    packaging/homebrew/fq.rb.in > /tmp/fq.rb
```

Verify before pushing (and after):

```sh
brew update
brew info topce/fq/fq            # version, URL, sha256
brew audit --strict topce/fq/fq  # style and correctness
brew install topce/fq/fq && brew test topce/fq/fq
```

`brew bump-formula-pr --url=... --sha256=... topce/fq/fq` does the same through
a PR if you prefer the review step.

### AUR (Arch Linux)

```sh
source_sha=$(curl -sL https://github.com/topce/fq/archive/refs/tags/v0.4.0.tar.gz \
             | shasum -a 256 | cut -d' ' -f1)
sed -e "s|@VERSION@|0.4.0|g" -e "s|@SHA256_SOURCE_TARBALL@|$source_sha|g" \
    packaging/aur/PKGBUILD.in > PKGBUILD
makepkg --printsrcinfo > .SRCINFO      # from a checkout of aur@aur.archlinux.org/fq
git add PKGBUILD .SRCINFO && git commit -m "fq 0.4.0" && git push
```

`makepkg -si` in a clean chroot (`makechrootpkg`) before pushing is worth the
few minutes: it also runs the `check()` suite.

### opam (macOS and Linux)

```sh
opam publish --tag v0.4.0 https://github.com/topce/fq
```

That opens a PR against `opam-repository`; after it is merged, `opam install fq`
works. opam-repository does not test the native Windows port, which is why
Windows has its own channels below.

### Not suitable

**Snap and Flatpak cannot ship fq.** Both confine the application: it would see
only its own sandbox and could neither enumerate nor kill anything outside it,
so the tool would list an empty world and quit exactly nothing. A Docker image
has the same problem unless run with `--pid=host`, and even then it needs the
host's `/proc`. Distro packages, the source tarball and Homebrew are the honest
options.

## Prebuilt binaries (optional, hand-made)

Only do this when someone can build and test the artifact on the real platform.
The archives are named `fq-<version>-<target>` (with `fq` or `fq.exe` inside,
plus `README.md`, `LICENSE`, `CHANGELOG.md`), where `<target>` is one of
`linux-x86_64`, `linux-x86_64-static`, `macos-x86_64`, `macos-arm64`,
`windows-x86_64`.

**macOS** (on the machine, native architecture):

```sh
dune build --profile release
name=fq-0.4.0-macos-arm64                     # or macos-x86_64 on an Intel Mac
mkdir -p dist/$name && cp _build/default/bin/main.exe dist/$name/fq
cp README.md LICENSE CHANGELOG.md dist/$name/
chmod 755 dist/$name/fq
(cd dist && tar -czf $name.tar.gz $name)
./dist/$name/fq --version && ./dist/$name/fq --help > /dev/null
```

**Linux** (on a Linux machine or VM — build on the *oldest* distribution you
want to support, so the glibc requirement stays low):

```sh
dune build --profile release
name=fq-0.4.0-linux-x86_64
mkdir -p dist/$name && cp _build/default/bin/main.exe dist/$name/fq
cp README.md LICENSE CHANGELOG.md dist/$name/
chmod 755 dist/$name/fq
(cd dist && tar -czf $name.tar.gz $name)
./dist/$name/fq --version && ./dist/$name/fq --list
```

A fully static musl build (`linux-x86_64-static`, for Alpine and anywhere the
glibc version is a problem) needs that toolchain — in an opam switch created
with `ocaml-variants.<version>+options,ocaml-option-musl,ocaml-option-static`:

```sh
dune build --profile release && file _build/default/bin/main.exe   # "statically linked"
```

**Windows** (on a Windows machine, with a native OCaml ≥ 5.1 and opam 2.2+):

```powershell
opam install . --deps-only
dune build --profile release
$name = "fq-0.4.0-windows-x86_64"
New-Item -ItemType Directory -Force "dist/$name" | Out-Null
Copy-Item _build/default/bin/main.exe "dist/$name/fq.exe"
Copy-Item README.md,LICENSE,CHANGELOG.md "dist/$name/"
Compress-Archive -Path "dist/$name" -DestinationPath "dist/$name.zip"
.\dist\$name\fq.exe --version
```

**Checksums and upload:**

```sh
cd dist && sha256sum ./*.tar.gz ./*.zip > SHA256SUMS && cat SHA256SUMS
gh release upload v0.4.0 ./*.tar.gz ./*.zip SHA256SUMS
```

`packaging/render.sh <version> SHA256SUMS <outdir> [<source-sha256>]` then fills
in the Scoop, WinGet, AUR, nfpm and Homebrew manifests from that `SHA256SUMS`
(the Windows zip must be present for the Scoop and WinGet ones), so no hash is
ever typed by hand. Attachment order matters: create the release first, upload
the archives, then render and publish the manifests — a manifest that points at
a URL which does not exist yet is a broken install for whoever tries first.

`.deb` and `.rpm` come from the Linux tarball via `packaging/nfpm.yaml.in`:

```sh
tar -xzf fq-0.4.0-linux-x86_64.tar.gz
nfpm package -f /tmp/fq-0.4.0/nfpm.yaml -p deb -t fq_0.4.0_amd64.deb
nfpm package -f /tmp/fq-0.4.0/nfpm.yaml -p rpm -t fq-0.4.0.x86_64.rpm
gh release upload v0.4.0 fq_0.4.0_amd64.deb fq-0.4.0.x86_64.rpm
```

## Windows package managers (need a Windows build)

Both point at the Windows zip, so they can only be published once that artifact
exists on the release page.

### Scoop

```sh
# render first: packaging/render.sh 0.4.0 SHA256SUMS /tmp/fq-0.4.0 "$source_sha"
cp /tmp/fq-0.4.0/scoop/fq.json ../scoop-bucket/bucket/fq.json
git -C ../scoop-bucket commit -am "fq 0.4.0" && git -C ../scoop-bucket push
```

Users then run `scoop bucket add topce https://github.com/topce/scoop-bucket`
once and `scoop install topce/fq` afterwards. The manifest carries `checkver`
and `autoupdate`, which read the hash out of our `SHA256SUMS`, so `scoop update`
picks new releases up on its own. The main `Extras` bucket has notability
criteria — propose it there only if the project gets that far.

### WinGet

```sh
mkdir -p ~/winget-pkgs/manifests/t/Topce/Fq/0.4.0
cp /tmp/fq-0.4.0/winget/Topce.Fq*.yaml ~/winget-pkgs/manifests/t/Topce/Fq/0.4.0/
# on Windows: winget validate --manifest <dir>   (or: wingetcreate validate <dir>)
cd ~/winget-pkgs && git checkout -b topce-fq-0.4.0 \
  && git add manifests/t/Topce && git commit -m "Add Topce.Fq 0.4.0" \
  && gh pr create --repo microsoft/winget-pkgs
```

There is no automation for this any more: every version is a PR to
`microsoft/winget-pkgs`, reviewed by their moderators. The manifests install fq
as a **portable** package — WinGet unpacks the zip and puts `fq.exe` on `PATH`
under the alias `fq`.

## Staged rollout

A CLI that kills processes has one catastrophic failure mode — killing the
wrong thing — and a published version cannot be un-downloaded, so anything
risky goes out in two stages:

1. **Canary**: `gh release create v0.4.0-rc.1 --prerelease --latest=false` (or
   publish the tag with `--prerelease`). No channel points at a prerelease, so
   only people who look for it see it.
2. **Verify on real machines** — at least one real Linux desktop session (X11
   *and* Wayland if possible), one Windows machine, one Mac (see below).
3. **Promote**: edit the release and untick *prerelease*, or push the final tag.
   Only now update Homebrew, AUR, opam, Scoop and WinGet.
4. **Watch the first 24 hours**: issues, downloads, and any report of a wrong
   application being killed (that one is a stop-ship).

## Verification

Run these against what users actually download, on real machines:

```sh
sha256sum -c SHA256SUMS
```

| Platform | Checks |
| --- | --- |
| Linux | `fq --list` lists your desktop apps and not shells; the picker kills only the chosen app; `fq --others -y -s` keeps the terminal alive and suspends; `fq -b wmctrl --list` agrees on X11; the static build runs on Alpine |
| Windows | `fq --list` shows windowed apps; `fq -y notepad` closes Notepad with unsaved text; `fq --others -y` does **not** close Windows Terminal; `fq --pid <unused> -y` exits 0; SmartScreen warning matches the unsigned-build note |
| macOS | `fq --list` matches the Force Quit dialog (⌥⌘⎋); `fq -y Safari` behaves like the dialog; `brew test topce/fq/fq` passes |

## Rollback

| Situation | Action | Time |
| --- | --- | --- |
| Bad tag, nothing published yet | `git push --delete origin v0.4.0 && git tag -d v0.4.0`, fix, re-tag | minutes |
| Bad release page, no channel updated | `gh release edit v0.4.0 --prerelease` (stops Scoop `autoupdate`), `gh release delete-asset`, publish a fixed patch release | minutes |
| Bad Homebrew formula | `git -C "$(brew --repo topce/fq)" revert HEAD && git -C "$(brew --repo topce/fq)" push` | minutes |
| Bad AUR package | revert the PKGBUILD commit and push (or delete the package) | minutes |
| Bad Scoop manifest | revert the bucket commit; users who already installed keep the binary but `scoop update` will not move them further | minutes |
| Bad WinGet manifest | open a PR removing the version directory, or supersede it with a patch release | days (moderation) |
| Bad opam release | opam-repository has no yank: publish a patch release, or a PR marking the version `available: false` | days |
| Wrong application killed (any version) | stop-ship: mark the release prerelease, open a pinned `safety` issue with the reproduction, publish nothing new until it is fixed | immediately |

Nothing restores the copies people already downloaded — that is what the canary
stage is for.

## Monitoring and upkeep

* **Issues** — label anything about the wrong process being killed as `safety`;
  an open `safety` issue freezes releases until it is fixed.
* **Downloads** — `gh release view v0.4.0 --json assets --jq '.assets[] | "\(.name) \(.downloadCount)"'`
  shows which platform people actually take, which is the hint about which
  channel deserves attention.
* **Channel drift** — after publishing a release, check that Homebrew, AUR,
  opam, Scoop and WinGet all show the new version.
* **Local test runs** — with no CI, the suite is only as good as the habit of
  running it: `dune runtest` before every commit that touches behaviour, and on
  a Windows machine before a release that claims Windows support.
* **Dependencies** — the project has no third-party OCaml dependencies, so there
  is no lockfile to audit; only the toolchain (OCaml, dune) moves.

## Known gaps

* **Windows binaries are unsigned.** SmartScreen shows "Windows protected your
  PC" on first run, and security software may flag a process-killing tool as a
  potentially unwanted application. Fix by signing with Azure Trusted Signing or
  [SignPath.io](https://signpath.io) (free for OSS), and by reporting a false
  positive to Microsoft if Defender complains. Until then say so in the release
  notes and publish the sha256 so users can verify.
* **macOS binaries are unsigned and unnotarized.** Homebrew builds from source,
  so its users never see a quarantine prompt; anyone downloading a tarball in a
  browser may need `xattr -d com.apple.quarantine fq`.
* **No Linux ARM64 or Windows ARM64 builds** — neither target is built today.
  Windows on ARM runs the x64 build through emulation.
* **Linux listing is a heuristic.** The README says what it includes and what it
  hides; a user who cannot find an application they launched from a terminal
  should be pointed at `fq --pid` or `-b wmctrl`.
