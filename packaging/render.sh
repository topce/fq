#!/bin/sh
# Render the packaging templates for a release.
#
#   packaging/render.sh <version> <SHA256SUMS> <output-dir> [<source-sha256>]
#
#   <version>       release version without the leading "v" (e.g. 0.4.0)
#   <SHA256SUMS>    the file published with the GitHub release
#   <output-dir>    where the rendered files are written
#   <source-sha256> sha256 of the v<version> source tarball
#                   (curl -sL .../archive/refs/tags/v<version>.tar.gz | shasum -a 256)
#                   When given, the AUR PKGBUILD and the Homebrew formula are
#                   rendered too; without it they are skipped.
#
# Renders, per channel:
#   scoop/fq.json                     Scoop manifest (topce/scoop-bucket)
#   winget/Topce.Fq*.yaml             WinGet manifests (microsoft/winget-pkgs)
#   aur/PKGBUILD                      AUR source package
#   nfpm.yaml                         .deb / .rpm description (nfpm)
#   homebrew/fq.rb                    Homebrew formula (topce/homebrew-fq tap)
#
# Nothing is published: the rendered files are meant to be reviewed, committed
# to the channel's repository and pushed. See docs/RELEASING.md.

set -eu

if [ $# -lt 3 ] || [ $# -gt 4 ]; then
  sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
fi

version=$1
sums=$2
out=$3
source_sha=${4:-}

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

if [ ! -f "$sums" ]; then
  echo "render.sh: no such checksum file: $sums" >&2
  exit 1
fi

# sha_of <file-name> -> the sha256 recorded for it, or nothing
sha_of() {
  awk -v want="$1" '$2 == want || $2 == "*" want { print $1; exit }' "$sums"
}

windows_zip="fq-$version-windows-x86_64.zip"
sha_windows=$(sha_of "$windows_zip")
if [ -z "$sha_windows" ]; then
  echo "render.sh: $sums has no checksum for $windows_zip" >&2
  echo "           (was the windows-x86_64 artifact built for this release?)" >&2
  exit 1
fi

date=$(date -u +%Y-%m-%d)

render() {
  src=$1
  dst=$2
  mkdir -p "$(dirname -- "$dst")"
  sed -e "s|@VERSION@|$version|g" \
      -e "s|@DATE@|$date|g" \
      -e "s|@SHA256_WINDOWS_X86_64@|$sha_windows|g" \
      -e "s|@SHA256_SOURCE_TARBALL@|$source_sha|g" \
      "$src" > "$dst"
  echo "rendered $dst"
}

render "$here/scoop/fq.json.in" "$out/scoop/fq.json"
render "$here/winget/Topce.Fq.yaml.in" "$out/winget/Topce.Fq.yaml"
render "$here/winget/Topce.Fq.installer.yaml.in" "$out/winget/Topce.Fq.installer.yaml"
render "$here/winget/Topce.Fq.locale.en-US.yaml.in" "$out/winget/Topce.Fq.locale.en-US.yaml"
render "$here/nfpm.yaml.in" "$out/nfpm.yaml"

if [ -n "$source_sha" ]; then
  render "$here/aur/PKGBUILD.in" "$out/aur/PKGBUILD"
  render "$here/homebrew/fq.rb.in" "$out/homebrew/fq.rb"
else
  echo "note: no source tarball sha256 given — skipped aur/PKGBUILD and homebrew/fq.rb" >&2
fi
