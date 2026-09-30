#!/usr/bin/env bash
# Shared helpers for the wrapper scripts. Source this file; it does nothing on its own.
#
# Written for the bash 3.2 that ships with macOS: no associative arrays, no mapfile.
# Every path is quoted because the repository may live in a folder with spaces in its name.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
submodule="$root/CotEditor"
patch_dir="$root/patches"
# Each patch's changes under Tests/ are kept apart, in a file of the same name in this folder, so that
# the code and its tests can be read on their own. Applying a patch applies both.
test_patch_dir="$patch_dir/tests"
test_path="Tests"
build_root="$root/.build"
default_workspace="$root/.work/CotEditor"

die() { echo "error: $*" >&2; exit 1; }
note() { echo "==> $*" >&2; }

# Git settings that could change how a patch is written or read are pinned, so that exported
# patches are byte-identical whatever the developer's own configuration is.
wrapper_git() {
    git -c core.quotePath=true -c diff.noprefix=false -c diff.mnemonicPrefix=false \
        -c diff.renames=false -c diff.external= -c color.ui=false -c apply.whitespace=nowarn "$@"
}

# The pinned upstream commit, read from the wrapper's staged gitlink rather than from the submodule
# checkout, whose HEAD may have moved. The staged value equals the committed one in normal use, and
# lets an upstream upgrade be exported and verified before the new gitlink is committed.
pinned_commit() {
    local commit
    commit="$(git -C "$root" ls-files --stage -- CotEditor | awk '$1 == "160000" {print $2}')"
    [[ -n "$commit" ]] || die "cannot read the CotEditor gitlink in $root"
    echo "$commit"
}

# The test part of a patch, if it has one: the file of the same name in test_patch_dir.
test_patch_for() {
    local patch="$1"
    local test_patch="$test_patch_dir/$(basename "$patch")"
    [[ -f "$test_patch" ]] && echo "$test_patch"
    return 0
}

# Fills the global array `patch_files` with the files that apply the given patches, in order: each
# patch, followed by its test part if it has one.
expand_patch_files() {
    patch_files=()
    local patch test_patch
    for patch in "$@"; do
        patch_files+=("$patch")
        test_patch="$(test_patch_for "$patch")"
        [[ -n "$test_patch" ]] && patch_files+=("$test_patch")
    done
    return 0
}

# Fills the global array `series` with every numbered patch, in application order. Their test parts
# are not listed; expand_patch_files adds them.
load_series() {
    series=()
    local patch
    for patch in "$patch_dir"/[0-9][0-9]-*.patch; do
        [[ -f "$patch" ]] && series+=("$patch")
    done
    [[ ${#series[@]} -gt 0 ]] || die "no numbered patches in $patch_dir"
}

# Fills the global array `selected` with the series up to and including the patch that `through`
# names: its number, such as 02, or its name after the number, or the start of it, such as `shell` for
# 02-shell. An empty `through` selects every patch. Calls load_series first.
select_through() {
    local through="$1" patch name match=""
    load_series
    selected=()
    if [[ -z "$through" ]]; then
        selected=("${series[@]}")
        return
    fi
    for patch in "${series[@]}"; do
        name="$(basename "$patch" .patch)"
        if [[ "$name" == "$through"-* || "${name#[0-9][0-9]-}" == "$through"* ]]; then
            [[ -z "$match" ]] || die "'$through' matches both $(basename "$match") and $(basename "$patch")"
            match="$patch"
        fi
    done
    [[ -n "$match" ]] || die "no patch in $patch_dir is numbered or named '$through'"
    for patch in "${series[@]}"; do
        selected+=("$patch")
        [[ "$patch" == "$match" ]] && break
    done
    return 0
}

# Where to clone upstream from: the submodule's repository when it is initialized, which works
# offline, otherwise the URL in .gitmodules.
upstream_source() {
    if git -C "$submodule" rev-parse --git-dir >/dev/null 2>&1; then
        echo "$submodule"
    else
        git -C "$root" config -f .gitmodules submodule.CotEditor.url
    fi
}

# Clones the pinned commit into a directory that must not exist yet.
fresh_checkout() {
    local target="$1" pin
    pin="$(pinned_commit)"
    [[ ! -e "$target" ]] || die "$target already exists"
    git clone --quiet --no-checkout "$(upstream_source)" "$target"
    git -C "$target" checkout --quiet --detach "$pin"
}

# Fails unless the checkout has no staged, unstaged or untracked changes.
require_clean() {
    local checkout="$1"
    git -C "$checkout" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
        || die "$checkout is not a git checkout (for the submodule: git submodule update --init --recursive)"
    [[ -z "$(git -C "$checkout" status --porcelain --untracked-files=all)" ]] \
        || die "$checkout has local changes; refusing to touch it"
}

# Applies patches in order to a clean checkout, each with its test part.
#
# The whole series is first applied to a private temporary index, so that a patch that does not
# apply on top of the previous ones is found before the working tree changes at all.
apply_series() {
    local checkout="$1"; shift
    require_clean "$checkout"

    local index patch
    expand_patch_files "$@"
    set -- "${patch_files[@]}"
    index="$(mktemp "${TMPDIR:-/tmp}/cot-tabs-index.XXXXXX")"
    rm -f "$index"
    (
        export GIT_INDEX_FILE="$index"
        trap 'rm -f "$GIT_INDEX_FILE"' EXIT
        git -C "$checkout" read-tree HEAD
        for patch in "$@"; do
            wrapper_git -C "$checkout" apply --cached --check "$patch" \
                || die "$(basename "$patch") does not apply on top of the patches before it"
            wrapper_git -C "$checkout" apply --cached "$patch"
        done
    )

    for patch in "$@"; do
        wrapper_git -C "$checkout" apply "$patch"
        echo "Applied $patch"
    done
}

# The checkout that builds of a prefix use. The scripts own it and replace its contents freely, so
# nothing else may be kept in it; the submodule and the workspace are never used for this.
prefix_checkout="$build_root/Checkout"

# Checks out a prefix of the series in prefix_checkout: the pinned commit with the patches in
# `selected` applied, or, when a workspace is given, that workspace's commit of the last selected
# patch. Only files that differ from the previous build are rewritten, so a build that follows
# builds only what changed.
checkout_prefix() {
    local workspace="$1" pin commit last index tree
    pin="$(pinned_commit)"
    last="$(basename "${selected[${#selected[@]}-1]}" .patch)"
    if [[ ! -d "$prefix_checkout/.git" ]]; then
        mkdir -p "$build_root"
        git clone --quiet --no-checkout "$(upstream_source)" "$prefix_checkout"
    fi
    git -C "$prefix_checkout" cat-file -e "$pin^{commit}" 2>/dev/null \
        || git -C "$prefix_checkout" fetch --quiet "$(upstream_source)" "$pin"

    if [[ -n "$workspace" ]]; then
        # The commit is found by its name, so that the prefix matches the patch files' order.
        commit="$(git -C "$workspace" log --format='%H %s' "$pin..HEAD" | awk -v name="$last" '$2 == name {print $1}')"
        [[ -n "$commit" ]] || die "the workspace $workspace has no commit named $last"
        [[ "$(echo "$commit" | wc -l | tr -d ' ')" == 1 ]] || die "the workspace $workspace has more than one commit named $last"
        [[ -z "$(git -C "$workspace" status --porcelain --untracked-files=no)" ]] \
            || note "warning: $workspace has uncommitted changes, which are not built; use --checkout to build them"
        git -C "$prefix_checkout" fetch --quiet "$workspace" HEAD
    else
        index="$(mktemp "${TMPDIR:-/tmp}/cot-tabs-index.XXXXXX")"
        rm -f "$index"
        tree="$(
            export GIT_INDEX_FILE="$index"
            trap 'rm -f "$GIT_INDEX_FILE"' EXIT
            git -C "$prefix_checkout" read-tree "$pin"
            expand_patch_files "${selected[@]}"
            for patch in "${patch_files[@]}"; do
                wrapper_git -C "$prefix_checkout" apply --cached "$patch" \
                    || die "$(basename "$patch") does not apply on top of the patches before it"
            done
            git -C "$prefix_checkout" write-tree
        )" || exit 1
        # A fixed identity and date give the same commit for the same patches.
        commit="$(GIT_AUTHOR_NAME=CotEditorPatch GIT_AUTHOR_EMAIL=build@localhost GIT_AUTHOR_DATE="2000-01-01T00:00:00Z" \
                  GIT_COMMITTER_NAME=CotEditorPatch GIT_COMMITTER_EMAIL=build@localhost GIT_COMMITTER_DATE="2000-01-01T00:00:00Z" \
                  git -C "$prefix_checkout" commit-tree "$tree" -p "$pin" -m "$last")" || exit 1
    fi

    git -C "$prefix_checkout" checkout --quiet --force --detach "$commit"
    git -C "$prefix_checkout" clean --quiet -d --force -x
    note "checked out $last$([[ -n "$workspace" ]] && echo " from the workspace") in $prefix_checkout"
}

# The tree a checkout's working files would commit as, untracked files included, without
# touching its index.
working_tree_id() {
    local checkout="$1" index tree
    index="$(mktemp "${TMPDIR:-/tmp}/cot-tabs-tree.XXXXXX")"
    rm -f "$index"
    tree="$(GIT_INDEX_FILE="$index" sh -c 'git -C "$1" read-tree HEAD && git -C "$1" add -A && git -C "$1" write-tree' _ "$checkout")"
    rm -f "$index"
    echo "$tree"
}
