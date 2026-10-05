#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin ]]; then
  echo "This script requires macOS and Xcode Command Line Tools." >&2
  exit 1
fi
prefix="$(brew --prefix)"
zig="${ZIG:-$prefix/opt/zig@0.16/bin/zig}"
if [[ ! -x "$zig" ]]; then
  echo "Install dependencies: brew bundle --file=Brewfile.macos" >&2
  exit 1
fi
if [[ "$($zig version)" != 0.16.* ]]; then
  echo "Suzume requires Zig 0.16.x; set ZIG to that executable." >&2
  exit 1
fi
if [[ ! -f deps/libnsfb/src/libnsfb.c ]]; then
  echo "Initialize sources first: git submodule update --init --recursive" >&2
  exit 1
fi
case "$(uname -m)" in
  arm64) arch=aarch64 ;;
  x86_64) arch=x86_64 ;;
  *) echo "Unsupported Mac architecture" >&2; exit 1 ;;
esac
"$zig" build -Doptimize=ReleaseSafe -Dstrip=true -Dtarget="$arch-macos.15.0" \
  --search-prefix "$prefix" --search-prefix "$prefix/opt/curl" \
  --search-prefix "$prefix/opt/sqlite" "$@"
python3 scripts/bundle-macos.py
ditto -c -k --keepParent zig-out/Suzume.app zig-out/Suzume-macos.zip
printf '\nLaunch: open zig-out/Suzume.app\n'
