#!/usr/bin/env bash
# Checks an app's signature and entitlements, and that shells and ssh run under them.
#
#   scripts/check-signing.sh [--through PATCH] [--workspace [DIR] | --checkout DIR] [--pty]
#
#   --through PATCH  the prefix whose app is checked, as for build.sh (default: every patch)
#   --workspace [DIR], --checkout DIR
#                    where the app is built from, as for build.sh (default: the patch files)
#   --pty            also run the PTY tests in a test host signed with the hardened runtime and
#                    the app's entitlements, and, for an app with remote files, the tests that
#                    launch ssh against scripts/remote-fixture.sh's server, which must be running
#
# An ad-hoc signed Release build of the app is made and inspected: the hardened runtime must be on,
# the app must contain only this Mac's architecture, and the App Sandbox must be on for the Tabs app
# and off for every later app, whose terminals need it off. Build settings alone are not trusted;
# the entitlements are read from the signed binary.
#
# The PTY check exists because Xcode signs test hosts without the hardened runtime, so ordinary test
# runs cannot show whether spawning a shell works under it. The host is re-signed with the runtime
# flag and its own entitlements, then the already built tests run against it.
#
# This is not a distribution check: a Developer ID signature and notarization need a team identity.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() { echo "Usage: $0 [--through PATCH] [--workspace [DIR] | --checkout DIR] [--pty]" >&2; exit 2; }

source_options=()
checkout="$prefix_checkout"
runs_pty=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --through) [[ $# -ge 2 ]] || usage; source_options+=(--through "$2"); shift 2 ;;
        --workspace)
            if [[ $# -ge 2 && "$2" != --* ]]; then source_options+=(--workspace "$2"); shift 2
            else source_options+=(--workspace); shift; fi
            ;;
        --checkout) [[ $# -ge 2 ]] || usage; checkout="$(cd "$2" && pwd)"; source_options+=(--checkout "$checkout"); shift 2 ;;
        --pty) runs_pty=true; shift ;;
        *) usage ;;
    esac
done

app="$("$(dirname "${BASH_SOURCE[0]}")/build.sh" "${source_options[@]}" --release --adhoc)"
entitlements="$(codesign -d --entitlements - --xml "$app" 2>/dev/null | plutil -convert xml1 -o - -)"
flags="$(codesign -dv "$app" 2>&1 | grep -o 'flags=[^ ]*')"
architectures="$(lipo -archs "$app/Contents/MacOS/CotEditor")"

note "app:           $app"
note "identifier:    $(codesign -dv "$app" 2>&1 | sed -n 's/^Identifier=//p')"
note "signature:     $flags"
note "architectures: $architectures"
note "entitlements:"
echo "$entitlements" | plutil -p - >&2

# Output is matched in variables rather than piped into `grep -q`: with pipefail, grep exiting at the
# first match makes the writer fail with SIGPIPE, which would turn a match into a failure.
failures=0
check() { if eval "$2"; then note "ok      $1"; else note "FAILED  $1"; failures=$((failures + 1)); fi; }
check "hardened runtime is on" '[[ "$flags" == *runtime* ]]'
if [[ "$(basename "$app")" == CotEditor-Tabs-* ]]; then
    check "App Sandbox is on" '[[ "$entitlements" == *com.apple.security.app-sandbox* ]]'
else
    check "App Sandbox is off" '[[ "$entitlements" != *com.apple.security.app-sandbox* ]]'
    check "no iCloud entitlements" '[[ "$entitlements" != *com.apple.developer.icloud* ]]'
fi
check "only $(uname -m)" '[[ "$architectures" == "$(uname -m)" ]]'
check "signature verifies" 'codesign --verify --deep --strict "$app" 2>/dev/null'

if $runs_pty; then
    [[ -f "$checkout/Tests/Sources/Models/TerminalPTYTests.swift" ]] || die "--pty needs an app with terminals"
    has_remote=false
    [[ -f "$checkout/Tests/Sources/Models/RemoteTransportTests.swift" ]] && has_remote=true
    derived="$build_root/DerivedData"
    project="$checkout/CotEditor.xcodeproj"
    # The ad-hoc entitlements, as for the app: without a team ID, library validation would refuse the
    # test host's own debug library under the hardened runtime.
    signing=(DEVELOPMENT_TEAM= CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual PROVISIONING_PROFILE_SPECIFIER=
             CODE_SIGN_ENTITLEMENTS_SUFFIX=-AdHoc)
    log="$build_root/logs/$(date +%Y%m%d-%H%M%S)-hardened-pty.log"
    mkdir -p "$build_root/logs"
    note "building for testing (log: $log)"
    xcodebuild -skipPackagePluginValidation -project "$project" -scheme CotEditor -configuration Debug \
        "${signing[@]}" -derivedDataPath "$derived" build-for-testing > "$log" 2>&1 || die "build failed; see $log"

    host="$derived/Build/Products/Debug/CotEditor.app"
    host_entitlements="$(mktemp "${TMPDIR:-/tmp}/cot-tabs-entitlements.XXXXXX")"
    trap 'rm -f "$host_entitlements"' EXIT
    codesign -d --entitlements - --xml "$host" > "$host_entitlements" 2>/dev/null
    for library in "$host"/Contents/MacOS/*.dylib; do
        [[ -f "$library" ]] && codesign --force --sign - "$library" 2>/dev/null
    done
    codesign --force --sign - --options runtime --entitlements "$host_entitlements" "$host" 2>/dev/null
    host_signature="$(codesign -dv "$host" 2>&1)"
    check "test host carries the hardened runtime" '[[ "$host_signature" == *"(adhoc,runtime)"* ]]'

    suites=(-only-testing:Tests/TerminalPTYTests)
    if $has_remote; then
        fixture="$build_root/remote-fixture"
        [[ -f "$fixture/sshd.pid" ]] && kill -0 "$(cat "$fixture/sshd.pid")" 2>/dev/null \
            || die "the remote check launches ssh against the test server; start it with scripts/remote-fixture.sh start"
        # xcodebuild passes variables prefixed with TEST_RUNNER_ to the tests, without the prefix.
        export TEST_RUNNER_COTEDITOR_REMOTE_FIXTURE="$fixture"
        suites+=(-only-testing:Tests/RemoteTransportTests)
    fi
    if xcodebuild -project "$project" -scheme CotEditor -configuration Debug -derivedDataPath "$derived" \
        test-without-building "${suites[@]}" >> "$log" 2>&1
    then
        note "ok      PTY$($has_remote && echo " and ssh") tests pass under the hardened runtime"
    else
        grep -E '^✘ Test [^ ]+ recorded an issue' "$log" | head -20 >&2 || true
        note "FAILED  tests under the hardened runtime; see $log"
        failures=$((failures + 1))
    fi
fi

[[ $failures -eq 0 ]] || die "$failures check(s) failed"
note "all signing checks passed"
