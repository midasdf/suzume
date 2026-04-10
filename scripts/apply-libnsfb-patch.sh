#!/usr/bin/env bash
# Apply patches/libnsfb-xim.patch inside deps/libnsfb when not already applied.
set -euo pipefail
patch_file="${1:?patch file}"
nsfb_dir="${2:?libnsfb directory}"
cd "$nsfb_dir"
if patch -p1 --dry-run -N --batch -i "$patch_file" >/dev/null 2>&1; then
  exec patch -p1 -N --batch -i "$patch_file"
fi
