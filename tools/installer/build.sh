#!/bin/bash
# Wraps an exported MayorStreet.exe in a Windows installer (see mayor_street.nsi).
#   tools/installer/build.sh path/to/MayorStreet.exe [out_dir]
# Needs NSIS: `apt-get install nsis` on Linux, or NSIS 3 on Windows (run from Git Bash).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
exe="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
out="${2:-$root/builds}"
mkdir -p "$out"
out="$(cd "$out" && pwd)"
version="$(sed -n 's/^config\/version="\(.*\)"/\1/p' "$root/project.godot")"
size_kb=$(( $(wc -c < "$exe") / 1024 ))
makensis -V2 -DEXE="$exe" -DVERSION="${version:-0.0.0}" -DSIZE_KB="$size_kb" \
	-DOUTFILE="$out/MayorStreet-Setup.exe" "$here/mayor_street.nsi"
echo "wrote $out/MayorStreet-Setup.exe"
