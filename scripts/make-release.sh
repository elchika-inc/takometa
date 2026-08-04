#!/bin/bash
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd -P)
repo_root=$(cd "$script_dir/.." && pwd -P)
release_root="$repo_root/dist/release"
source_guide="$repo_root/はじめにお読みください.txt"
source_release="$repo_root/.docs/runbooks/RELEASE.md"
source_readme="$repo_root/README.md"
source_checks="$script_dir/release-checks"
injection_spec=${TAKOMETA_RELEASE_INJECT:-}
injections=("")
prerelease_mode=${TAKOMETA_RELEASE_PRERELEASE:-0}

cleanup_armed=0
run_succeeded=0
version=
intermediate_app=
staging_root=
zip_path=
sha_path=
dmg_path=
dmg_sha_path=
dmg_src=
dmg_mount=
dmg_attached=0
extract_root=
runtime_root=
runtime_checks="$source_checks"
runtime_release="$source_release"
runtime_readme="$source_readme"
release_root_ready=0

fail() {
    local gate=$1
    shift
    echo "ERROR[$gate]: $*" >&2
    exit 1
}

is_release_child() {
    local target=$1
    [[ "$release_root_ready" -eq 1 && -n "$target" && "$target" == "$release_root"/* ]] \
        || return 1
    local parent canonical_parent
    parent=$(dirname "$target")
    canonical_parent=$(realpath "$parent") || return 1
    [[ "$canonical_parent" == "$release_root" ]]
}

prepare_release_root() {
    local dist_root="$repo_root/dist"
    [[ ! -L "$dist_root" && ! -L "$release_root" ]] \
        || fail N-3 "release output path must not traverse symlinks: $release_root"
    mkdir -p "$release_root"
    local canonical_root
    canonical_root=$(realpath "$release_root") \
        || fail N-3 "release output path is unreadable: $release_root"
    [[ "$canonical_root" == "$release_root" ]] \
        || fail N-3 "release output path must not traverse symlinks: $release_root"
    release_root_ready=1
}

safe_remove() {
    local target=$1
    [[ -n "$target" ]] || return 0
    if ! is_release_child "$target"; then
        echo "ERROR[N-3]: refusing to delete outside release output: $target" >&2
        return 1
    fi
    if [[ -e "$target" || -L "$target" ]]; then
        rm -rf -- "$target"
    fi
}

cleanup() {
    local status=$?
    trap - EXIT
    if [[ "$dmg_attached" -eq 1 && -n "$dmg_mount" ]]; then
        hdiutil detach "$dmg_mount" -quiet >/dev/null 2>&1 || true
        dmg_attached=0
    fi
    if [[ "$cleanup_armed" -eq 1 && "$run_succeeded" -eq 0 ]]; then
        safe_remove "$intermediate_app" || true
        safe_remove "$staging_root" || true
        safe_remove "$zip_path" || true
        safe_remove "$sha_path" || true
        safe_remove "$dmg_path" || true
        safe_remove "$dmg_sha_path" || true
    fi
    safe_remove "$dmg_src" || true
    safe_remove "$dmg_mount" || true
    safe_remove "$extract_root" || true
    safe_remove "$runtime_root" || true
    exit "$status"
}
trap cleanup EXIT

validate_version_and_tag() {
    [[ $# -eq 1 ]] || fail V-4 "usage: make-release.sh <version>"
    version=$1
    if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9][A-Za-z0-9.-]*)?$ ]]; then
        fail V-4 "version must be X.Y.Z or X.Y.Z-<suffix> without a v prefix"
    fi
    local numeric=${version%%-*}
    if [[ "$numeric" == "0.0.0" ]]; then
        fail V-4 "0.0.0 and its suffixed forms are reserved"
    fi
    if [[ "$prerelease_mode" != "0" && "$prerelease_mode" != "1" ]]; then
        fail V-4 "TAKOMETA_RELEASE_PRERELEASE must be 0 or 1"
    fi
    if [[ "$prerelease_mode" == "1" && "$version" != *-* ]]; then
        fail V-4 "prerelease mode requires a suffixed version"
    fi

    local tagged_commit
    if ! tagged_commit=$(git -C "$repo_root" rev-parse -q --verify "refs/tags/v${version}^{commit}"); then
        fail V-4 "local tag v${version} is missing or unreadable"
    fi
    local head_commit
    if ! head_commit=$(git -C "$repo_root" rev-parse HEAD); then
        fail V-4 "HEAD is unreadable"
    fi
    if [[ "$tagged_commit" != "$head_commit" ]]; then
        fail V-4 "tag v${version} does not point to HEAD"
    fi
}

parse_injections() {
    [[ -n "$injection_spec" ]] || return 0
    if [[ "$injection_spec" == ,* || "$injection_spec" == *, \
        || "$injection_spec" == *,,* ]]; then
        fail N-15b "injection list contains an empty value: $injection_spec"
    fi

    IFS=',' read -r -a injections <<< "$injection_spec"
    local injection
    for injection in "${injections[@]}"; do
        case "$injection" in
            resolved-guide|single-arch|strip-exec-bit|plant-identifier|mismatch-minos|empty-guide|guide-placeholder|drop-guide-heading|version-mismatch|drop-plist-key|extra-file|desync-guide|plant-forbidden-form|dmg-extra-file)
                ;;
            empty-refset:codename-identifiers|empty-refset:guide-headings|empty-refset:zip-toplevel|empty-refset:forbidden-forms)
                ;;
            *)
                fail N-15b "unknown injection: $injection"
                ;;
        esac
    done

    [[ "$version" == *-* ]] \
        || fail N-49 "injection runs require a pre-release suffix"
    echo "WARNING[N-49]: injection run is verification-only: $injection_spec" >&2
}

has_injection() {
    local expected=$1 injection
    for injection in "${injections[@]}"; do
        [[ "$injection" == "$expected" ]] && return 0
    done
    return 1
}

replace_todo_placeholders() {
    local target=$1
    local replacement="$runtime_root/placeholder-replacement.tmp"
    sed 's/TODO(N-10)/検証用解決済み(N-49)/g' "$target" > "$replacement"
    mv "$replacement" "$target"
}

require_clean_tree() {
    local status
    if ! status=$(git -C "$repo_root" status --porcelain --untracked-files=normal); then
        fail V-3 "could not inspect the working tree"
    fi
    [[ -z "$status" ]] || fail V-3 "working tree is not clean"
}

require_ignored_outputs() {
    git -C "$repo_root" check-ignore -q dist/release \
        || fail N-12 "dist/release is not ignored by git"
}

require_architectures() {
    local binary=$1
    local phase=$2
    local architectures
    if ! architectures=$(lipo -archs "$binary"); then
        fail V-1 "$phase binary architectures are unreadable"
    fi
    local have_arm64=0
    local have_x86_64=0
    local architecture
    for architecture in $architectures; do
        [[ "$architecture" == "arm64" ]] && have_arm64=1
        [[ "$architecture" == "x86_64" ]] && have_x86_64=1
    done
    if [[ "$have_arm64" -ne 1 || "$have_x86_64" -ne 1 ]]; then
        fail V-1 "$phase binary must contain exact arm64 and x86_64 slices; found: $architectures"
    fi
}

prepare_runtime_inputs() {
    runtime_root="$release_root/.runtime-${version}"
    safe_remove "$runtime_root"
    mkdir -p "$runtime_root/checks"
    cp "$source_checks"/*.txt "$runtime_root/checks/"
    cp "$source_release" "$runtime_root/RELEASE.md"
    cp "$source_readme" "$runtime_root/README.md"
    runtime_checks="$runtime_root/checks"
    runtime_release="$runtime_root/RELEASE.md"
    runtime_readme="$runtime_root/README.md"

    if has_injection resolved-guide; then
        replace_todo_placeholders "$runtime_release"
        replace_todo_placeholders "$runtime_readme"
    fi

    local injection refset
    for injection in "${injections[@]}"; do
        if [[ "$injection" == empty-refset:* ]]; then
            refset=${injection#empty-refset:}
            : > "$runtime_checks/${refset}.txt"
        fi
    done
}

load_refset() {
    local name=$1
    local destination=$2
    local manifest="$runtime_checks/${name}.txt"
    [[ -r "$manifest" ]] || fail N-43 "reference set is unreadable: $name"
    awk 'NF && $0 !~ /^[[:space:]]*#/' "$manifest" > "$destination"
    [[ -s "$destination" ]] || fail N-43 "reference set has no effective entries: $name"
}

extract_guide_section() {
    local source=$1
    local destination=$2
    awk '
        /<!-- TAKOMETA_GUIDE_BEGIN -->/ { capture = 1; next }
        /<!-- TAKOMETA_GUIDE_END -->/ { capture = 0 }
        capture
    ' "$source" > "$destination"
}

normalize_version() {
    local raw=$1
    local major minor
    IFS=. read -r major minor _rest <<< "$raw"
    [[ -n "$major" && -n "$minor" ]] || return 1
    printf '%s.%s\n' "$major" "$minor"
}

validate_v2() {
    local app=$1
    local binary="$app/Contents/MacOS/Takometa"
    [[ -f "$app/Contents/Info.plist" ]] || fail V-2 "Info.plist is missing after extraction"
    [[ -f "$binary" ]] || fail V-2 "executable is missing after extraction"
    [[ -d "$app/Contents/_CodeSignature" ]] || fail V-2 "code signature directory is missing"
    [[ -x "$binary" ]] || fail V-2 "executable bit is missing after extraction"
    codesign --verify --deep --strict "$app" \
        || fail V-2 "extracted app signature verification failed"
}

validate_v6() {
    local extracted_top=$1
    local refset_file="$runtime_root/codenames.effective"
    load_refset codename-identifiers "$refset_file"

    local file_count
    file_count=$(find "$extracted_top" -type f | wc -l | tr -d ' ')
    [[ "$file_count" -ge 4 ]] || fail V-6 "inspected file count is below the minimum: $file_count"

    local term file
    while IFS= read -r term; do
        while IFS= read -r file; do
            if grep -aFq -- "$term" "$file"; then
                fail V-6 "codename identifier detected: $term"
            fi
        done < <(find "$extracted_top" -type f -print)
    done < "$refset_file"
}

validate_v7() {
    local app=$1
    local binary="$app/Contents/MacOS/Takometa"
    local plist_version package_version arm_version intel_version
    plist_version=$(plutil -extract LSMinimumSystemVersion raw -o - "$app/Contents/Info.plist") \
        || fail V-7 "LSMinimumSystemVersion is unreadable"

    local package_json="$runtime_root/package.json"
    swift package --package-path "$repo_root" dump-package > "$package_json" \
        || fail V-7 "Package.swift platforms are unreadable"
    package_version=$(plutil -extract platforms.0.version raw -o - "$package_json") \
        || fail V-7 "Package.swift macOS platform is missing"
    package_version=$(normalize_version "$package_version") \
        || fail V-7 "Package.swift platform version cannot be normalized"
    plist_version=$(normalize_version "$plist_version") \
        || fail V-7 "Info.plist platform version cannot be normalized"

    arm_version=$(xcrun vtool -arch arm64 -show-build "$binary" \
        | awk '$1 == "minos" { print $2; exit }')
    intel_version=$(xcrun vtool -arch x86_64 -show-build "$binary" \
        | awk '$1 == "minos" { print $2; exit }')
    [[ -n "$arm_version" && -n "$intel_version" ]] \
        || fail V-7 "binary min OS is missing for one or more slices"
    arm_version=$(normalize_version "$arm_version") \
        || fail V-7 "arm64 min OS cannot be normalized"
    intel_version=$(normalize_version "$intel_version") \
        || fail V-7 "x86_64 min OS cannot be normalized"

    if [[ "$plist_version" != "$package_version" \
        || "$arm_version" != "$package_version" \
        || "$intel_version" != "$package_version" ]]; then
        fail V-7 "minimum OS mismatch: plist=$plist_version package=$package_version arm64=$arm_version x86_64=$intel_version"
    fi
}

validate_v8() {
    local guide=$1
    [[ -r "$guide" && -s "$guide" ]] || fail V-8 "bundled guide is missing, unreadable, or empty"

    if grep -Fq 'TODO(N-10)' "$guide"; then
        if [[ "$prerelease_mode" == "1" ]]; then
            echo "WARNING[N-48]: prerelease mode allows TODO(N-10) in the bundled guide" >&2
        else
            fail V-8 "TODO(N-10) remains in the bundled guide"
        fi
    fi

    local headings="$runtime_root/headings.effective"
    load_refset guide-headings "$headings"
    local heading
    while IFS= read -r heading; do
        grep -Fqx -- "## $heading" "$guide" \
            || fail V-8 "required guide heading is missing: $heading"
    done < "$headings"
}

validate_v9() {
    local app=$1
    local plist="$app/Contents/Info.plist"
    local key
    for key in LSUIElement CFBundleIdentifier CFBundleExecutable \
        CFBundleShortVersionString CFBundleVersion LSMinimumSystemVersion TakometaBuildCommit; do
        plutil -extract "$key" raw -o - "$plist" >/dev/null \
            || fail V-9 "required Info.plist key is missing: $key"
    done

    local plist_version plist_commit head_commit
    plist_version=$(plutil -extract CFBundleShortVersionString raw -o - "$plist")
    plist_commit=$(plutil -extract TakometaBuildCommit raw -o - "$plist")
    head_commit=$(git -C "$repo_root" rev-parse HEAD) || fail V-9 "HEAD is unreadable"
    [[ "$plist_version" == "$version" ]] \
        || fail V-9 "bundle version mismatch: expected=$version actual=$plist_version"
    [[ "$plist_commit" == "$head_commit" ]] \
        || fail V-9 "build commit mismatch: expected=$head_commit actual=$plist_commit"
}

validate_v10() {
    local extracted_top=$1
    local expected="$runtime_root/toplevel.expected"
    local actual="$runtime_root/toplevel.actual"
    load_refset zip-toplevel "$expected"
    LC_ALL=C sort -o "$expected" "$expected"
    find "$extracted_top" -mindepth 1 -maxdepth 1 -exec basename {} \; \
        | LC_ALL=C sort > "$actual"
    diff -u "$expected" "$actual" >/dev/null \
        || fail V-10 "zip top-level entries do not match the expected set"
}

validate_v11() {
    local guide=$1
    local release_guide="$runtime_root/release-guide.txt"
    local readme_guide="$runtime_root/readme-guide.txt"
    extract_guide_section "$runtime_release" "$release_guide"
    extract_guide_section "$runtime_readme" "$readme_guide"

    if has_injection plant-forbidden-form; then
        printf '%s\n' 'xattr -cr "$HOME/Applications/Takometa.app"' >> "$release_guide"
        printf '%s\n' 'xattr -cr "$HOME/Applications/Takometa.app"' >> "$readme_guide"
    fi

    diff -u "$guide" "$release_guide" >/dev/null \
        || fail V-11 "bundled guide differs from RELEASE.md template"
    diff -u "$guide" "$readme_guide" >/dev/null \
        || fail V-11 "bundled guide differs from README instructions"
}

validate_v12() {
    local guide=$1
    local patterns="$runtime_root/forbidden.effective"
    load_refset forbidden-forms "$patterns"
    local pattern
    while IFS= read -r pattern; do
        if grep -E -q -- "$pattern" "$guide"; then
            fail V-12 "forbidden form detected in bundled guide: $pattern"
        fi
    done < "$patterns"
}

observe_v5() {
    local binary=$1
    local absolute_paths="$runtime_root/absolute-paths.txt"
    LC_ALL=C grep -aoE \
        '/[A-Za-z][A-Za-z0-9._+@%=-]+(/[A-Za-z0-9._+@%=-]+)+' \
        "$binary" | LC_ALL=C sort -u > "$absolute_paths" || true
    if [[ -s "$absolute_paths" ]]; then
        local count
        count=$(wc -l < "$absolute_paths" | tr -d ' ')
        echo "WARNING[V-5]: distribution binary contains $count absolute path string(s); record the observation in .docs/runbooks/RELEASE.md" >&2
        sed -n '1,20p' "$absolute_paths" >&2
    else
        echo "INFO[V-5]: no absolute path strings observed" >&2
    fi
}

validate_version_and_tag "$@"
parse_injections
require_clean_tree
require_ignored_outputs

intermediate_app="$release_root/Takometa.app"
staging_root="$release_root/Takometa-${version}"
zip_path="$release_root/Takometa-${version}.zip"
sha_path="$zip_path.sha256"

prepare_release_root
cleanup_armed=1
safe_remove "$intermediate_app"
safe_remove "$staging_root"
safe_remove "$zip_path"
safe_remove "$sha_path"
prepare_runtime_inputs

build_args=(--package-path "$repo_root" -c release)
if ! has_injection single-arch; then
    build_args+=(--arch arm64 --arch x86_64)
fi
swift build "${build_args[@]}"
binary_dir=$(swift build "${build_args[@]}" --show-bin-path)
binary_path="$binary_dir/TakometaApp"
head_commit=$(git -C "$repo_root" rev-parse HEAD)

"$script_dir/lib/make-bundle.sh" \
    "$binary_path" "$intermediate_app" "$version" "$head_commit"
require_architectures "$intermediate_app/Contents/MacOS/Takometa" intermediate

mkdir -p "$staging_root"
ditto "$intermediate_app" "$staging_root/Takometa.app"
cp "$source_guide" "$staging_root/はじめにお読みください.txt"
staging_guide="$staging_root/はじめにお読みください.txt"

if has_injection resolved-guide; then
    replace_todo_placeholders "$staging_guide"
fi

for injection in "${injections[@]}"; do
    case "$injection" in
        plant-identifier)
            printf '%s\n' amber_ladder >> "$staging_guide"
            ;;
        empty-guide)
            : > "$staging_guide"
            ;;
        guide-placeholder)
            printf '%s\n' 'TODO(N-10): injected placeholder' >> "$staging_guide"
            ;;
        drop-guide-heading)
            awk '$0 != "## 照合手順"' "$staging_guide" > "$runtime_root/guide.tmp"
            cp "$runtime_root/guide.tmp" "$staging_guide"
            ;;
        extra-file)
            printf '%s\n' unexpected > "$staging_root/unexpected.txt"
            ;;
        desync-guide)
            printf '%s\n' 'injected guide difference' >> "$staging_guide"
            ;;
        plant-forbidden-form)
            printf '%s\n' 'xattr -cr "$HOME/Applications/Takometa.app"' >> "$staging_guide"
            ;;
    esac
done

ditto -c -k --sequesterRsrc --keepParent "$staging_root" "$zip_path"
zip_hash=$(shasum -a 256 "$zip_path" | awk '{ print $1 }')
printf '%s  %s\n' "$zip_hash" "$(basename "$zip_path")" > "$sha_path"

extract_root=$(mktemp -d "$release_root/.extract-${version}.XXXXXX")
ditto -x -k "$zip_path" "$extract_root"
extracted_top="$extract_root/Takometa-${version}"
extracted_app="$extracted_top/Takometa.app"
extracted_binary="$extracted_app/Contents/MacOS/Takometa"
extracted_guide="$extracted_top/はじめにお読みください.txt"

for injection in "${injections[@]}"; do
    case "$injection" in
        strip-exec-bit)
            chmod a-x "$extracted_binary"
            ;;
        mismatch-minos)
            plutil -replace LSMinimumSystemVersion -string 14.0 "$extracted_app/Contents/Info.plist"
            codesign --force --sign - "$extracted_app"
            ;;
        version-mismatch)
            plutil -replace CFBundleShortVersionString -string 9.9.9 "$extracted_app/Contents/Info.plist"
            codesign --force --sign - "$extracted_app"
            ;;
        drop-plist-key)
            plutil -remove CFBundleIdentifier "$extracted_app/Contents/Info.plist"
            codesign --force --sign - "$extracted_app"
            ;;
    esac
done

require_architectures "$extracted_binary" extracted
validate_v2 "$extracted_app"
observe_v5 "$extracted_binary"
validate_v6 "$extracted_top"
validate_v7 "$extracted_app"
validate_v8 "$extracted_guide"
validate_v9 "$extracted_app"
validate_v10 "$extracted_top"
validate_v11 "$extracted_guide"
validate_v12 "$extracted_guide"

# 全ゲート通過後の検証済みコンテンツ（extracted_top）から DMG を組む。
# 中身（.app・案内）は検証済みのため、DMG では入れ物と /Applications への
# ドラッグ先ショートカットのみを新たに加える。
dmg_path="$release_root/Takometa-${version}.dmg"
dmg_sha_path="${dmg_path}.sha256"
dmg_src=$(mktemp -d "$release_root/.dmgsrc-${version}.XXXXXX")
ditto "$extracted_app" "$dmg_src/Takometa.app"
cp "$extracted_guide" "$dmg_src/はじめにお読みください.txt"
ln -s /Applications "$dmg_src/Applications"

if has_injection dmg-extra-file; then
    printf '%s\n' unexpected > "$dmg_src/unexpected.txt"
fi

safe_remove "$dmg_path" || fail N-3 "cannot clear previous dmg"
hdiutil create -volname "Takometa ${version}" -srcfolder "$dmg_src" \
    -format UDZO -ov "$dmg_path" >/dev/null \
    || fail V-13 "dmg creation failed"

# V-13: DMG がマウントでき、トップレベルが期待どおりで、内部の .app が
# 署名検証を通ること。受け取り手が実際に開くのはこの DMG である。
dmg_mount=$(mktemp -d "$release_root/.dmgmnt-${version}.XXXXXX")
hdiutil attach "$dmg_path" -nobrowse -readonly -mountpoint "$dmg_mount" -quiet \
    || fail V-13 "dmg failed to mount"
dmg_attached=1
[[ -d "$dmg_mount/Takometa.app" ]] || fail V-13 "dmg is missing Takometa.app"
[[ -f "$dmg_mount/はじめにお読みください.txt" ]] || fail V-13 "dmg is missing the guide"
[[ -L "$dmg_mount/Applications" ]] || fail V-13 "dmg is missing the Applications drag target"
codesign --verify --deep --strict "$dmg_mount/Takometa.app" \
    || fail V-13 "dmg app fails signature verification"
dmg_visible=$(ls "$dmg_mount")
expected_visible=$'Applications\nTakometa.app\nはじめにお読みください.txt'
[[ "$(printf '%s\n' "$dmg_visible" | sort)" == "$(printf '%s\n' "$expected_visible" | sort)" ]] \
    || fail V-13 "dmg contains unexpected top-level entries"
hdiutil detach "$dmg_mount" -quiet >/dev/null 2>&1 || true
dmg_attached=0

dmg_hash=$(shasum -a 256 "$dmg_path" | awk '{ print $1 }')
printf '%s  %s\n' "$dmg_hash" "$(basename "$dmg_path")" > "$dmg_sha_path"

run_succeeded=1
echo "OK: $dmg_path"
echo "OK: $dmg_sha_path"
echo "OK: $zip_path"
echo "OK: $sha_path"
