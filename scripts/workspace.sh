#!/usr/bin/env bash
# Creates a patch workspace: a clone of the pinned upstream commit with one commit per patch.
#
#   scripts/workspace.sh [DIR]      (default: .work/CotEditor)
#
# Each commit is named after its patch file (for example `02-shell`) and holds the patch
# with its test part, so the series can be edited as ordinary commits. Change a patch by amending its commit, for example:
#
#   git -C .work/CotEditor commit --fixup=<commit of 01-tabs>
#   git -C .work/CotEditor rebase --autosquash <pinned commit>
#
# Later patches are rebased onto the change, which shows at once whether they still apply. Then run
# scripts/export-patches.sh to write the patch files back.
#
# The workspace is separate from the CotEditor submodule, so the submodule stays at plain upstream.
# An existing directory is never replaced.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[[ $# -le 1 ]] || { echo "Usage: $0 [DIR]" >&2; exit 2; }
workspace="${1:-$default_workspace}"

load_series
mkdir -p "$(dirname "$workspace")"
fresh_checkout "$workspace"
git -C "$workspace" switch --quiet --create patches

# Commits need an identity; a local fallback is used only if git has none configured.
identity=()
git -C "$workspace" config user.name >/dev/null || identity+=(-c "user.name=CotEditor Tabs")
git -C "$workspace" config user.email >/dev/null || identity+=(-c "user.email=cotedit-tabs@localhost")

for patch in "${series[@]}"; do
    # A patch and its test part become one commit, as export-patches.sh splits them again.
    expand_patch_files "$patch"
    for file in "${patch_files[@]}"; do
        wrapper_git -C "$workspace" apply --index "$file" \
            || die "${file#"$root"/} does not apply on top of the patches before it"
    done
    git ${identity[@]+"${identity[@]}"} -C "$workspace" commit --quiet --no-verify -m "$(basename "$patch" .patch)"
done

note "Workspace ready at $workspace (branch 'patches', based on $(pinned_commit | cut -c1-12))"
git -C "$workspace" log --oneline "$(pinned_commit)..HEAD"
