#!/bin/bash
###############################################################################
# my_shortcuts.sh   (invoked on PATH as: my-shortcuts)
#
# Print the WolfPack-DFT toolkit README -- the project quick-reference guide.
# Uses 'glow' for rendered Markdown if available; falls back to plain cat.
#
# The README is found next to this script (following the ~/.local/bin symlink
# back to the toolkit directory), so the command works from any folder and no
# matter where you cloned the toolkit.
#
# USAGE
#   my-shortcuts              # print (rendered if glow is installed)
#   my-shortcuts | less       # paginate the output
###############################################################################

# Resolve the real path of this script even when invoked through a symlink in
# ~/.local/bin, then look for Readme.md in the same directory.
src="${BASH_SOURCE[0]}"
while [[ -h "$src" ]]; do
    target="$(readlink "$src")"
    if [[ "$target" == /* ]]; then src="$target"; else src="$(dirname "$src")/$target"; fi
done
script_dir="$(cd -P "$(dirname "$src")" >/dev/null 2>&1 && pwd)"

# Search order: alongside the resolved script, then the legacy install dir.
readme=""
for candidate in "$script_dir/Readme.md" "$HOME/Useful_scripts/Readme.md"; do
    if [[ -f "$candidate" ]]; then readme="$candidate"; break; fi
done

if [[ -z "$readme" ]]; then
    echo "Readme.md not found next to the toolkit (looked in $script_dir)." >&2
    exit 1
fi

if command -v glow >/dev/null 2>&1; then
    glow "$readme"
else
    cat "$readme"
fi
