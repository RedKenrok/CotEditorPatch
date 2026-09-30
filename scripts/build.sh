#!/usr/bin/env bash
# Builds or tests the app of a prefix of the patch series.
#
#   scripts/build.sh [options]
#
#   --through PATCH  build the patches up to and including PATCH: its name, such as tabs, shell,
#                    webpage or remote, or its number, such as 02 (default: every patch)
#   --workspace [DIR]
#                    take the prefix from the workspace's commits (default DIR: .work/CotEditor)
#                    instead of from the patch files; uncommitted changes are not included
#   --checkout DIR   build the working tree of DIR as it is, uncommitted changes included, instead
#                    of a prefix; for development in the workspace
#   --release        Release configuration instead of Debug
#   --arch arm64|x86_64|both
#                    build for Apple Silicon or Intel Macs, or one after the other for both
#                    (default: this Mac's architecture); every app has one architecture, which is
#                    added to its name, as in CotEditor-Tabs-arm64.app
#   --test           run the focused test suites of the patches in the tree
#   --test-all       run the whole test plan
#   --adhoc          sign ad-hoc (no team needed) instead of building unsigned
#
# A prefix is built in .build/Checkout, which the scripts own; the submodule and the workspace are
# never changed. Build products and logs go to .build/ as well. The product is always CotEditor.app,
# so a successful build is also copied to .build/Apps/<Debug|Release>/, named after the app's bundle
# identifier (CotEditor-Tabs, CotEditor-Shell, CotEditor-Web or CotEditor-Remote) and its architecture,
# replacing the previous copy of that app, and that path is printed. On failure the compiler errors
# and failed tests are listed and the full log is kept.
#
# Every build shares one derived data folder, so builds run one after another. Checking out another
# prefix rewrites only the files that differ, and only those are compiled again.
#
# When the SFTP test server of scripts/remote-fixture.sh is running, its folder is passed to the
# tests, which then also run the remote suites against a real sshd; otherwise those are skipped.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() { sed -n '2,33p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2; }

through=""
through_given=false
workspace=""
checkout=""
configuration=Debug
action=build
signs_adhoc=false
architecture=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --through) [[ $# -ge 2 ]] || usage; through="$2"; through_given=true; shift 2 ;;
        --workspace)
            if [[ $# -ge 2 && "$2" != --* ]]; then workspace="$(cd "$2" && pwd)"; shift 2
            else workspace="$default_workspace"; shift; fi
            ;;
        --checkout) [[ $# -ge 2 ]] || usage; checkout="$(cd "$2" && pwd)"; shift 2 ;;
        --release) configuration=Release; shift ;;
        --arch) [[ $# -ge 2 ]] || usage; architecture="$2"; shift 2 ;;
        --test) action=test; shift ;;
        --test-all) action=test-all; shift ;;
        --adhoc) signs_adhoc=true; shift ;;
        -h|--help) usage ;;
        *) usage ;;
    esac
done

native_architecture="$(uname -m)"
[[ -n "$architecture" ]] || architecture="$native_architecture"
case "$architecture" in
    arm64|x86_64) architectures=("$architecture") ;;
    both) architectures=(arm64 x86_64) ;;
    *) die "unknown architecture '$architecture' (use arm64, x86_64 or both)" ;;
esac
[[ "$action" == build || "$architecture" == "$native_architecture" ]] \
    || die "tests run on this Mac, so --arch can only be $native_architecture with --test or --test-all"

if [[ -n "$checkout" ]]; then
    ! $through_given && [[ -z "$workspace" ]] || die "--checkout builds a working tree as it is; it cannot be combined with --through or --workspace"
else
    select_through "$through"
    checkout_prefix "$workspace"
    checkout="$prefix_checkout"
fi

project="$checkout/CotEditor.xcodeproj"
[[ -d "$project" ]] || die "no CotEditor.xcodeproj in $checkout"

# The suites that cover the patches, as far as the tree has them.
focused_tests=()
for suite in DirectoryTabTests DirectoryTabArchiveTests DirectoryDocumentTests \
    TerminalSessionTests TerminalColorsTests TerminalPTYTests \
    WebPageNavigationPolicyTests WebPageSessionTests \
    RemoteSFTPCodecTests RemoteTransportTests RemoteRecoveryTests RemoteSaveTests RemoteDocumentTests \
    RemoteDirectoryListingTests RemoteDirectoryTreeTests RemoteFolderPickerTests RemoteFolderChangeTests RemoteAskpassTests RemoteTerminalTests
do
    [[ -f "$checkout/Tests/Sources/Models/$suite.swift" ]] && focused_tests+=("$suite")
done

# SwiftTerm compiles a Metal shader, and once it is in the package graph the app builds it.
if grep -q '"swiftterm"' "$project/project.xcworkspace/xcshareddata/swiftpm/Package.resolved" 2>/dev/null \
    && [[ "$(xcodebuild -showComponent MetalToolchain 2>/dev/null || true)" != *"Status: installed"* ]]
then
    die "SwiftTerm needs Xcode's Metal Toolchain; install it with: xcodebuild -downloadComponent MetalToolchain"
fi

# xcodebuild passes variables prefixed with TEST_RUNNER_ to the tests, without the prefix.
fixture="$build_root/remote-fixture"
if [[ "$action" != build && -f "$fixture/sshd.pid" ]] && kill -0 "$(cat "$fixture/sshd.pid")" 2>/dev/null; then
    export TEST_RUNNER_COTEDITOR_REMOTE_FIXTURE="$fixture"
    note "remote fixture: $fixture"
fi

# Builds or tests once, for one architecture.
run() {
    local architecture="$1" log label status product copy identifier app_name thins_copy=false
    local arguments=(-skipPackagePluginValidation -project "$project" -scheme CotEditor -configuration "$configuration"
                     -derivedDataPath "$build_root/DerivedData")
    if $signs_adhoc; then
        # The suffix selects the ad-hoc entitlements, as upstream's CI does: iCloud needs a provisioning
        # profile, and without a team ID library validation cannot succeed.
        arguments+=(DEVELOPMENT_TEAM= CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual PROVISIONING_PROFILE_SPECIFIER=
                    CODE_SIGN_ENTITLEMENTS_SUFFIX=-AdHoc)
    else
        arguments+=(CODE_SIGNING_ALLOWED=NO)
    fi
    # Every build has a single architecture. For this Mac's own, only the active architecture is built:
    # upstream's Release configuration otherwise builds every architecture in ARCHS. Build plugins that
    # run during the build (SwiftTerm has one) are built for the active architecture as well, which is
    # the one that can run here.
    #
    # The other architecture cannot be built on its own: ARCHS or a destination with that architecture
    # also applies to the plugins, and a plugin built for the other architecture cannot run on a Mac
    # without Rosetta. Such a build is made for any Mac, and the copy keeps only the requested
    # architecture once it finishes.
    if [[ "$action" == build && "$architecture" != "$native_architecture" ]]; then
        arguments+=(-destination "generic/platform=macOS")
        thins_copy=true
    elif [[ "$action" == build ]]; then
        arguments+=(-destination "platform=macOS,arch=$architecture" ONLY_ACTIVE_ARCH=YES)
    fi
    case "$action" in
        build) arguments+=(build) ;;
        test) arguments+=(test); for suite in "${focused_tests[@]}"; do arguments+=("-only-testing:Tests/$suite"); done ;;
        test-all) arguments+=(test -testPlan Tests) ;;
    esac

    mkdir -p "$build_root/logs"
    # A prefix checkout's commit is named after its last patch; any other checkout goes by its folder.
    if [[ "$checkout" == "$prefix_checkout" ]]; then
        label="$(git -C "$checkout" log -1 --format=%s)"
    else
        label="$(basename "$checkout")"
    fi
    label="${label//[^A-Za-z0-9.-]/_}"
    log="$build_root/logs/$(date +%Y%m%d-%H%M%S)-${label:0:40}-$configuration-$architecture-$action.log"
    note "$action $configuration for $architecture in $checkout"
    note "log: $log"

    if xcodebuild "${arguments[@]}" > "$log" 2>&1; then
        status=0
    else
        status=$?
    fi

    # Summaries only: the raw log is long and interleaves unrelated system messages.
    grep -E '^[^ ].*error: ' "$log" | grep -vE '^[0-9]{4}-[0-9]{2}-[0-9]{2} ' | sort -u | head -40 >&2 || true
    grep -E '^✘ Test [^ ]+ recorded an issue' "$log" | head -40 >&2 || true
    grep -E '^[✔✘] Test run with' "$log" >&2 || true

    [[ $status -eq 0 ]] || die "xcodebuild failed with status $status; see $log"
    [[ "$action" == build ]] || return 0

    # The copy is named after the app: upstream's identifier is the Tabs app, and each later app has
    # an identifier of its own that ends in its name.
    product="$build_root/DerivedData/Build/Products/$configuration/CotEditor.app"
    identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$product/Contents/Info.plist")"
    case "$identifier" in
        com.coteditor.CotEditor) app_name=CotEditor-Tabs ;;
        local.coteditor-tabs.*) app_name="${identifier#local.coteditor-tabs.}" ;;
        *) die "unknown bundle identifier $identifier" ;;
    esac

    # Renaming the bundle folder leaves its signature intact; ditto keeps the bundle's symlinks and
    # extended attributes. An incremental build replaces files inside the bundle without updating the
    # bundle folder's own date, and ditto copies that date, so it is set to the time of this build.
    copy="$build_root/Apps/$configuration/$app_name-$architecture.app"
    mkdir -p "$(dirname "$copy")"
    rm -rf "$copy"
    ditto "$product" "$copy"
    if $thins_copy; then
        # Each architecture in a universal binary carries its own signature, so keeping one leaves
        # the app's signature valid.
        local file archs
        while IFS= read -r -d '' file; do
            archs="$(lipo -archs "$file" 2>/dev/null)" || continue
            [[ "$archs" == *" "* ]] || continue
            lipo "$file" -thin "$architecture" -output "$file.thin" && mv "$file.thin" "$file" \
                || die "cannot extract $architecture from $file"
        done < <(find "$copy" -type f -print0)
        if $signs_adhoc; then
            codesign --verify --deep --strict "$copy" 2>/dev/null || die "the $architecture copy's signature does not verify: $copy"
        fi
    fi
    touch "$copy"
    echo "$copy"
}

for each in "${architectures[@]}"; do
    run "$each"
done
