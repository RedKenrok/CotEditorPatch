#!/usr/bin/env bash
# Writes the patch files from a patch workspace's commits, then verifies them.
#
#   scripts/export-patches.sh [DIR]   (default: .work/CotEditor, made by scripts/workspace.sh)
#
# Every commit after the pinned upstream commit becomes one patch, named after the commit subject,
# which must look like `03-short-name`. Each patch is the delta from the commit before it, so later
# patches never repeat earlier ones. A patch is written as two files of that name: its changes under
# Tests/ in patches/tests/, and all its other changes in patches/. Uncommitted changes and merge commits are refused, since they
# would not end up in any patch or could not be ordered.
#
# Existing patch files without a matching commit are reported and left in place; remove them by hand
# if the patch was dropped on purpose.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[[ $# -le 1 ]] || { echo "Usage: $0 [DIR]" >&2; exit 2; }
workspace="${1:-$default_workspace}"
[[ -d "$workspace" ]] || die "no workspace at $workspace; create one with scripts/workspace.sh"

require_clean "$workspace"
pin="$(pinned_commit)"
git -C "$workspace" merge-base --is-ancestor "$pin" HEAD \
    || die "the workspace is not based on the pinned commit $pin"
[[ -z "$(git -C "$workspace" rev-list --merges "$pin..HEAD")" ]] \
    || die "the workspace history contains merge commits; rebase it into one commit per patch"

commits=()
while IFS= read -r commit; do commits+=("$commit"); done < <(git -C "$workspace" rev-list --reverse "$pin..HEAD")
[[ ${#commits[@]} -gt 0 ]] || die "the workspace has no commits after $pin"

staging="$(mktemp -d "${TMPDIR:-/tmp}/cot-tabs-export.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
mkdir -p "$staging/tests" "$test_patch_dir"

previous_number=0
names=()
for commit in "${commits[@]}"; do
    name="$(git -C "$workspace" log -1 --format=%s "$commit")"
    [[ "$name" =~ ^([0-9]{2})-[a-z0-9][a-z0-9-]*$ ]] \
        || die "commit $(echo "$commit" | cut -c1-12) is named '$name'; patch commits must be named like 03-short-name"
    number=$((10#${BASH_REMATCH[1]}))
    [[ $number -gt $previous_number ]] || die "'$name' is out of order; patch numbers must increase along the history"
    previous_number=$number
    names+=("$name")

    wrapper_git -C "$workspace" diff --binary --no-ext-diff --src-prefix=a/ --dst-prefix=b/ "$commit^" "$commit" \
        -- . ":(exclude)$test_path" > "$staging/$name.patch"
    wrapper_git -C "$workspace" diff --binary --no-ext-diff --src-prefix=a/ --dst-prefix=b/ "$commit^" "$commit" \
        -- "$test_path" > "$staging/tests/$name.patch"
    [[ -s "$staging/$name.patch" ]] || die "'$name' changes nothing outside $test_path; a patch needs code of its own"
done

# Writes one exported file, or removes the test part of a patch that no longer changes any test.
publish() {
    local staged="$1" target="$2" label="$3"
    if [[ ! -s "$staged" ]]; then
        if [[ -f "$target" ]]; then
            rm "$target"
            note "removed    $label (no test changes)"
        fi
        return 0
    fi
    if cmp -s "$staged" "$target"; then
        note "unchanged  $label"
    else
        cp "$staged" "$target"
        note "written    $label"
    fi
}

for name in "${names[@]}"; do
    publish "$staging/$name.patch" "$patch_dir/$name.patch" "patches/$name.patch"
    publish "$staging/tests/$name.patch" "$test_patch_dir/$name.patch" "patches/tests/$name.patch"
done

for existing in "$patch_dir"/[0-9][0-9]-*.patch "$test_patch_dir"/[0-9][0-9]-*.patch; do
    [[ -f "$existing" ]] || continue
    printf '%s\n' "${names[@]}" | grep -qx "$(basename "$existing" .patch)" \
        || note "warning: ${existing#"$root"/} has no commit in the workspace"
done

"$(dirname "${BASH_SOURCE[0]}")/verify-patches.sh" --workspace "$workspace"
