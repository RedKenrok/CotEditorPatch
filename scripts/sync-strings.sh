#!/usr/bin/env bash
# Updates the string catalogs the patches touch from the strings the compiler found in the sources.
#
#   scripts/sync-strings.sh [--checkout DIR] [--no-build] [CATALOG...]
#
#   --checkout DIR   the patched checkout (default: .work/CotEditor, the patch workspace, which has
#                    every patch and so every string)
#   --no-build       use the existing build output instead of building first
#   CATALOG          catalogs to sync, relative to the checkout (default: every catalog the checkout
#                    changes or adds relative to the pinned commit)
#
# This is what Xcode does when it builds in the IDE: `xcstringstool sync` merges the compiler's
# .stringsdata output into each catalog, adding new keys with their default values and comments.
# Translations and review states are kept.
#
# Catalogs that also exist upstream are never rewritten as a whole. The tool re-sorts the languages
# of every entry when it writes a file, and the app target's output does not cover every string such
# a catalog holds, so a full sync would rewrite thousands of upstream lines. Instead, a temporary copy
# is synced, and only the entries it adds are spliced into the original text; entries whose English
# text or comment changed are reported for updating by hand. Catalogs added by a patch are owned by
# it, so they are synced in place, with stale marking.
#
# New entries get English only. Add translations, marked `needs_review`, in the same order of
# languages as the catalog's other entries.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

checkout="$default_workspace"
builds=true
catalogs=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --checkout) [[ $# -ge 2 ]] || die "--checkout needs a directory"; checkout="$2"; shift 2 ;;
        --no-build) builds=false; shift ;;
        -*) echo "Usage: $0 [--checkout DIR] [--no-build] [CATALOG...]" >&2; exit 2 ;;
        *) catalogs+=("$1"); shift ;;
    esac
done
checkout="$(cd "$checkout" && pwd)"
pin="$(pinned_commit)"

# The derived data folder is shared by every checkout, so the output must be from this one.
$builds && "$(dirname "${BASH_SOURCE[0]}")/build.sh" --checkout "$checkout" >/dev/null

objects="$build_root/DerivedData/Build/Intermediates.noindex/CotEditor.build/Debug/CotEditor.build/Objects-normal"
stringsdata=()
while IFS= read -r -d '' file; do stringsdata+=("$file"); done < <(find "$objects" -name '*.stringsdata' -print0 2>/dev/null)
[[ ${#stringsdata[@]} -gt 0 ]] || die "no compiler string output in $objects; build $checkout first"

if [[ ${#catalogs[@]} -eq 0 ]]; then
    while IFS= read -r path; do catalogs+=("$path"); done < <(
        { git -C "$checkout" diff --name-only "$pin" -- '*.xcstrings'
          git -C "$checkout" ls-files --others --exclude-standard -- '*.xcstrings'; } | sort -u)
    [[ ${#catalogs[@]} -gt 0 ]] || die "the checkout changes no string catalogs"
fi

# Runs the tool on one catalog. It reports upstream's own duplicate-comment notices on every run, so
# its output is only shown when it fails.
sync_catalog() {
    local catalog="$1"; shift
    local output
    if ! output="$(xcrun xcstringstool sync "$catalog" "$@" --stringsdata "${stringsdata[@]}" 2>&1)"; then
        echo "$output" >&2
        die "xcstringstool could not sync $catalog"
    fi
}


# Splices the entries a synced copy added into the original catalog text, keeping its formatting.
splice_added_entries() {
    python3 - "$1" "$2" <<'PYTHON'
import collections, json, sys

original_path, synced_path = sys.argv[1], sys.argv[2]
text = open(original_path, encoding="utf-8").read()
original = json.loads(text, object_pairs_hook=collections.OrderedDict)["strings"]
synced = json.load(open(synced_path, encoding="utf-8"), object_pairs_hook=collections.OrderedDict)["strings"]

def english(entry):
    return entry.get("localizations", {}).get("en", {}).get("stringUnit", {}).get("value")

for key, entry in synced.items():
    if key in original and (original[key].get("comment") != entry.get("comment") or
                            (english(entry) is not None and english(original[key]) not in (None, english(entry)))):
        print(f"warning: '{key}' changed in the sources; update it by hand", file=sys.stderr)

added = [key for key in synced if key not in original]
for key in sorted(added):
    body = json.dumps({key: synced[key]}, indent=2, ensure_ascii=False).replace('": ', '" : ')
    body = "\n".join("  " + line for line in body.splitlines()[1:-1])
    keys = list(json.loads(text, object_pairs_hook=collections.OrderedDict)["strings"])
    following = next((existing for existing in keys if existing > key), None)
    if following is None:
        # after the last entry: the strings object closes with a line "  }," followed by the version
        position = text.rindex("\n  },\n")
        text = text[:position] + ",\n" + body + text[position:]
    else:
        marker = "\n    " + json.dumps(following, ensure_ascii=False) + " : {"
        position = text.index(marker) + 1
        text = text[:position] + body + ",\n" + text[position:]
    print(f"added {key}", file=sys.stderr)

json.loads(text)
open(original_path, "w", encoding="utf-8").write(text)
PYTHON
}


for catalog in "${catalogs[@]}"; do
    [[ -f "$checkout/$catalog" ]] || die "no catalog at $checkout/$catalog"
    before="$(shasum "$checkout/$catalog")"
    
    if git -C "$checkout" cat-file -e "$pin:$catalog" 2>/dev/null; then
        # The tool matches catalogs to string tables by file name, so the copy keeps the name.
        scratch="$(mktemp -d "${TMPDIR:-/tmp}/cot-tabs-catalog.XXXXXX")"
        copy="$scratch/$(basename "$catalog")"
        cp "$checkout/$catalog" "$copy"
        sync_catalog "$copy" --skip-marking-strings-stale
        splice_added_entries "$checkout/$catalog" "$copy"
        rm -rf "$scratch"
    else
        sync_catalog "$checkout/$catalog"
    fi
    
    if [[ "$(shasum "$checkout/$catalog")" == "$before" ]]; then
        note "unchanged  $catalog"
    else
        note "updated    $catalog (review the new entries, then commit them to their patch)"
    fi
done
