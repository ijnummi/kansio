#!/bin/bash
# Builds 7-Zip's command-line program `7zz` from a pinned, checksum-verified source release (P2-3).
#
#   Tools/fetch-7zip.sh            → prints the path of the built 7zz (cached in build/7zip-<version>/)
#
# The source comes from 7-Zip's official GitHub releases (github.com/ip7z/7zip, linked from 7-zip.org). Nothing
# is built if the checksum doesn't match. Licence: GNU LGPL + unRAR restriction (DOC/License.txt, copied into the app).
set -euo pipefail
cd "$(dirname "$0")/.."

version="26.06"
tag="2606"
sha256="a4e374c8f864f51df48c2cfd0e1413ec3b2ea030deae852d6a655402ebb61ac4"
url="https://github.com/ip7z/7zip/releases/download/$version/7z$tag-src.tar.xz"

dir="build/7zip-$version"
arch="$(uname -m)"   # arm64 | x86_64
case "$arch" in
  arm64) mak="cmpl_mac_arm64.mak"; out="b/m_arm64/7zz" ;;
  x86_64) mak="cmpl_mac_x64.mak"; out="b/m_x64/7zz" ;;
  *) echo "unsupported architecture $arch" >&2; exit 1 ;;
esac
bundle="$dir/src/CPP/7zip/Bundles/Alone2"

if [[ -x "$bundle/$out" ]]; then
  echo "$bundle/$out"
  exit 0
fi

mkdir -p "$dir"
tarball="$dir/7z$tag-src.tar.xz"
if [[ ! -f "$tarball" ]]; then
  echo "downloading 7-Zip $version source…" >&2
  curl -fsSL --retry 2 -o "$tarball.part" "$url"
  mv "$tarball.part" "$tarball"
fi
actual="$(shasum -a 256 "$tarball" | cut -d' ' -f1)"
if [[ "$actual" != "$sha256" ]]; then
  echo "checksum mismatch for $tarball: $actual (expected $sha256)" >&2
  rm -f "$tarball"
  exit 1
fi
rm -rf "$dir/src"
mkdir -p "$dir/src"
tar -xf "$tarball" -C "$dir/src"

echo "building 7zz ($arch)…" >&2
( cd "$bundle" && make -j"$(sysctl -n hw.ncpu)" -f "../../$mak" >"$PWD/../../../../../build.log" 2>&1 ) || {
  echo "7-Zip build failed; see $dir/build.log" >&2
  exit 1
}
echo "$bundle/$out"
