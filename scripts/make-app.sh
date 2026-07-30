#!/bin/bash
set -euo pipefail

if [[ $# -gt 1 ]]; then
    echo "usage: make-app.sh [version]" >&2
    exit 1
fi

script_dir=$(cd "$(dirname "$0")" && pwd -P)
repo_root=$(cd "$script_dir/.." && pwd -P)
version=${1:-0.0.0-dev}

swift build --package-path "$repo_root" -c release
binary_dir=$(swift build --package-path "$repo_root" -c release --show-bin-path)
binary_path="$binary_dir/TakometaApp"
app_path="$repo_root/dist/Takometa.app"

if commit=$(git -C "$repo_root" rev-parse HEAD 2>/dev/null); then
    if [[ -n "$(git -C "$repo_root" status --porcelain --untracked-files=normal)" ]]; then
        commit="${commit}-dirty"
    fi
else
    commit=unknown
fi

"$script_dir/lib/make-bundle.sh" "$binary_path" "$app_path" "$version" "$commit"
echo "OK: $app_path"
