#!/usr/bin/env bash
# Returns the CotEditor submodule to the pinned upstream commit, ready for apply-patches.sh.
#
#   scripts/reset-submodule.sh [--yes] [--clean-ignored]
#
#   --yes            do not ask for confirmation (required when not run from a terminal)
#   --clean-ignored  also delete ignored files, such as build byproducts inside the submodule
#
# Nothing is lost: local changes, including untracked files, are first saved as a stash in the
# submodule's repository. The script prints how to inspect or restore it. An uninitialized
# submodule is simply initialized.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

confirmed=false
cleans_ignored=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --yes) confirmed=true; shift ;;
        --clean-ignored) cleans_ignored=true; shift ;;
        *) echo "Usage: $0 [--yes] [--clean-ignored]" >&2; exit 2 ;;
    esac
done

pin="$(pinned_commit)"

if ! git -C "$submodule" rev-parse --git-dir >/dev/null 2>&1; then
    note "initializing the submodule at $(echo "$pin" | cut -c1-12)"
    git -C "$root" submodule update --init --recursive -- CotEditor
    exit 0
fi

head="$(git -C "$submodule" rev-parse HEAD)"
changes="$(git -C "$submodule" status --porcelain --untracked-files=all)"
ignored=""
$cleans_ignored && ignored="$(git -C "$submodule" clean -ndX)"

if [[ "$head" == "$pin" && -z "$changes" && -z "$ignored" ]]; then
    note "the submodule is already clean at the pinned commit $(echo "$pin" | cut -c1-12)"
    exit 0
fi

[[ "$head" == "$pin" ]] || note "HEAD is $(git -C "$submodule" log -1 --format='%h %s' HEAD), not the pinned commit"
if [[ -n "$changes" ]]; then
    note "local changes to be stashed ($(echo "$changes" | wc -l | tr -d ' ') paths):"
    echo "$changes" | head -20 >&2
fi
[[ -z "$ignored" ]] || { note "ignored files to be deleted:"; echo "$ignored" | head -20 >&2; }

if ! $confirmed; then
    [[ -t 0 ]] || die "not running in a terminal; pass --yes to confirm"
    read -r -p "Reset the submodule to $(echo "$pin" | cut -c1-12)? [y/N] " answer
    [[ "$answer" == [yY] || "$answer" == [yY][eE][sS] ]] || die "canceled; nothing was changed"
fi

if [[ -n "$changes" ]]; then
    message="reset-submodule $(date '+%Y-%m-%d %H:%M:%S') from $(git -C "$submodule" rev-parse --short HEAD)"
    git -C "$submodule" stash push --quiet --include-untracked -m "$message"
    note "saved as stash@{0} in CotEditor ($message)"
    note "inspect:  git -C CotEditor stash show --include-untracked -p stash@{0}"
    note "restore:  git -C CotEditor stash apply stash@{0}   (on the commit it was made from)"
fi

$cleans_ignored && git -C "$submodule" clean -fdqX
git -C "$root" submodule update --init --recursive -- CotEditor

[[ -z "$(git -C "$submodule" status --porcelain --untracked-files=all)" ]] || die "the submodule still has changes"
note "the submodule is clean at the pinned commit $(git -C "$submodule" rev-parse --short HEAD)"
