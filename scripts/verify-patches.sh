#!/usr/bin/env bash
# Checks that the patch series installs cleanly, in every supported combination.
#
#   scripts/verify-patches.sh [--workspace DIR] [--build] [--test] [--keep]
#
# For each prefix of the series (01; 01+02; …), a fresh clone of the pinned upstream commit
# is patched with scripts/apply-patches.sh's procedure, each patch with its test part. Every patch must
# be refused on plain upstream and on every shorter prefix than the one it follows, since each depends
# on all the ones before it. Test parts are applied only together with their patch, so the refusals
# are checked for the patches alone.
#
#   --workspace DIR  also require the fully patched tree to equal the workspace's committed tree
#   --build          build the app of each prefix
#   --test           build the app of each prefix and run its focused tests
#   --keep           keep the temporary checkouts and print where they are

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

workspace=""
builds=false
runs_tests=false
keeps=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --workspace) [[ $# -ge 2 ]] || die "--workspace needs a directory"; workspace="$2"; shift 2 ;;
        --build) builds=true; shift ;;
        --test) runs_tests=true; builds=true; shift ;;
        --keep) keeps=true; shift ;;
        *) echo "Usage: $0 [--workspace DIR] [--build] [--test] [--keep]" >&2; exit 2 ;;
    esac
done

load_series
scratch="$(mktemp -d "${TMPDIR:-/tmp}/cot-tabs-verify.XXXXXX")"
if $keeps; then
    trap 'note "checkouts kept in $scratch"' EXIT
else
    trap 'rm -rf "$scratch"' EXIT
fi

# A patch must not apply before the patch it follows: that is what makes the dependency explicit.
# Checks every patch after the prefix, except the one that comes next.
check_refusals() {
    local checkout="$1" length="$2" name="$3" index
    for (( index = length + 1; index < count; index++ )); do
        if wrapper_git -C "$checkout" apply --check "${series[index]}" 2>/dev/null; then
            die "$(basename "${series[index]}") applies to $name, so it would not depend on the patches before it"
        fi
        note "refused on $name: $(basename "${series[index]}")"
    done
}

count=${#series[@]}
fresh_checkout "$scratch/upstream"
check_refusals "$scratch/upstream" 0 "plain upstream"

for (( length = 1; length <= count; length++ )); do
    checkout="$scratch/prefix-$length"
    prefix=("${series[@]:0:length}")
    name="$(for patch in "${prefix[@]}"; do basename "$patch" .patch; done | paste -sd+ -)"
    note "applying $name"
    fresh_checkout "$checkout"
    apply_series "$checkout" "${prefix[@]}" >/dev/null
    check_refusals "$checkout" "$length" "upstream+$name"

    if $runs_tests; then
        "$(dirname "${BASH_SOURCE[0]}")/build.sh" --checkout "$checkout" --test
    elif $builds; then
        "$(dirname "${BASH_SOURCE[0]}")/build.sh" --checkout "$checkout" >/dev/null
    fi
done

if [[ -n "$workspace" ]]; then
    expected="$(git -C "$workspace" rev-parse 'HEAD^{tree}')"
    actual="$(working_tree_id "$scratch/prefix-$count")"
    [[ "$expected" == "$actual" ]] || die "the patched tree ($actual) differs from the workspace ($expected)"
    note "patched tree matches the workspace"
fi

note "all $count patch combinations verified"
