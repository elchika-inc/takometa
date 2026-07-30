#!/bin/bash
set -euo pipefail

if [[ $# -ne 4 ]]; then
    echo "usage: make-bundle.sh <absolute-binary> <absolute-output-app> <version> <build-commit>" >&2
    exit 1
fi

binary_path=$1
app_path=$2
version=$3
build_commit=$4

if [[ "$binary_path" != /* || "$app_path" != /* ]]; then
    echo "error: binary and output paths must be absolute" >&2
    exit 1
fi
if [[ ! -f "$binary_path" || ! -x "$binary_path" ]]; then
    echo "error: input binary is missing or not executable: $binary_path" >&2
    exit 1
fi
if [[ "$(basename "$app_path")" != "Takometa.app" ]]; then
    echo "error: output must name Takometa.app" >&2
    exit 1
fi
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9][A-Za-z0-9.-]*)?$ ]]; then
    echo "error: invalid version: $version" >&2
    exit 1
fi

output_parent=$(dirname "$app_path")
mkdir -p "$output_parent"
output_parent=$(realpath "$output_parent")
expected_app="$output_parent/Takometa.app"
if [[ "$app_path" != "$expected_app" ]]; then
    echo "error: output path must be canonical: $expected_app" >&2
    exit 1
fi

# 削除対象は呼び出し元が絶対パスで指定した Takometa.app そのものに限定する。
if [[ -e "$app_path" || -L "$app_path" ]]; then
    rm -rf -- "$app_path"
fi

contents_path="$app_path/Contents"
executable_path="$contents_path/MacOS/Takometa"
plist_path="$contents_path/Info.plist"

mkdir -p "$contents_path/MacOS"
cp "$binary_path" "$executable_path"
chmod 755 "$executable_path"

plutil -create xml1 "$plist_path"
plutil -insert CFBundleExecutable -string Takometa "$plist_path"
plutil -insert CFBundleIdentifier -string dev.naoto24kawa.takometa "$plist_path"
plutil -insert CFBundleInfoDictionaryVersion -string 6.0 "$plist_path"
plutil -insert CFBundleName -string Takometa "$plist_path"
plutil -insert CFBundlePackageType -string APPL "$plist_path"
plutil -insert CFBundleShortVersionString -string "$version" "$plist_path"
plutil -insert CFBundleVersion -string "${version%%-*}" "$plist_path"
plutil -insert LSMinimumSystemVersion -string 15.0 "$plist_path"
plutil -insert LSUIElement -bool true "$plist_path"
plutil -insert NSHumanReadableCopyright -string "Copyright © 2026 Naoto Nishikawa" "$plist_path"
plutil -insert TakometaBuildCommit -string "$build_commit" "$plist_path"
plutil -lint "$plist_path"

codesign --force --sign - "$app_path"
