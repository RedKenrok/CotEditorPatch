# AGENTS.md

How to develop and maintain this repository, for people and coding agents alike. Read these first:

- [`README.md`](README.md): what the project does for users, the builds, requirements, and how to build and test.
- [`docs/`](docs/README.md): how each patch works, which patch is responsible for what, and the recorded evidence.

This file only covers how to work on the patches.

## Layout

`CotEditor/` is a git submodule pinned to an upstream commit. The features live in numbered patches in `patches/`, each described in the matching file in `docs/`:

- `01-tabs.patch`: the tab-system foundation. It applies to plain upstream and must stay usable on its own.
- `02-shell.patch`: shell tabs. It applies on top of patch 1, and makes the app unsandboxed.
- `03-webpage.patch`: webpage tabs. It applies on top of patches 1 and 2.
- `04-remote.patch`: editing files on SSH servers. It applies on top of patches 1 to 3.

Each patch is two files of the same name: `patches/02-shell.patch` holds its code, resources and settings, and `patches/tests/02-shell.patch` its changes under `Tests/`, so that each can be read on its own. They always go together: applying a patch applies its test part after it, and a patch without test changes has no test part. The workspace keeps them in one commit, and `export-patches.sh` splits it by path.

Each app is built from a prefix of the series: the Tabs app from patch 1, the Shell app from patches 1 and 2, the Web app from patches 1 to 3, the Remote app from all of them. A patched tree therefore contains exactly one app, and a later patch changes an earlier patch's code and settings directly, as any patch changes upstream's.

All scripts are in `scripts/`, with shared helpers in `scripts/lib.sh` (sourced, not run). Build output and logs go to `.build/` and the patch workspace to `.work/`; both are ignored by git.

## Rules

1. **Never edit the `CotEditor/` submodule to develop.** It stays at plain upstream, and the wrapper never commits a patched gitlink. Develop in the patch workspace (`scripts/workspace.sh`), then export.
2. **Each patch is a delta from the one before it.** Never let a later patch repeat an earlier one's changes. `scripts/verify-patches.sh` fails if a patch applies before the patch it follows.
3. **General tab-system work belongs in patch 1**, even if only a later patch needs it at first: tab model, tab strip, content host, tab commands, close and restoration plumbing, member adoption, the presentation and archive properties of `DataDocument`, and the contract for tabs that are not files (`DirectoryTabItem`, `DirectoryTabKind`). A later patch should only add its own kind of tab or document on top: a new kind of tab conforms to `DirectoryTabItem` and is registered in `DirectoryTabKind.registered`, with no branch of its own in patch 1's code.
4. **A feature's code is plain code in the patch that adds it.** There are no compilation conditions or file exclusions for features: a tree has one app, so nothing needs hiding. Shared files are edited directly, and test files are ordinary files.
   - Terminal code lives in `CotEditor/Sources/Terminal/`, webpage code in `CotEditor/Sources/WebPages/`, remote code in `CotEditor/Sources/Remote/`, and a new feature gets a folder of its own. The file names start with the feature's name, so a file's patch is clear at a glance.
   - Work that makes a later feature easier, but is not that feature, may go into an earlier patch, as rule 3 says for tab-system work.
5. **Build settings go into upstream's own configurations.** A patch that changes the app's identity or entitlements edits `Configurations/CotEditor.xcconfig` and upstream's `CotEditor.entitlements` and `CotEditor-AdHoc.entitlements`, with a comment explaining why. It adds no scheme, build configuration or xcconfig. Each app after patch 1 has its own bundle identifier (`local.coteditor-tabs.CotEditor-<Name>`), from which `build.sh` names the copy. Upstream's `CotEditor-Sparkle` scheme is left as it is; this project does not build it.
6. **Never reset or overwrite someone's work.** The scripts refuse dirty checkouts and existing target folders, and `reset-submodule.sh` stashes before resetting. Keep it that way in any new script.
7. **Record changes in one place each.**
   - How a patch works, and its evidence: that patch's file in `docs/`. The responsibility table: `docs/README.md`.
   - What users see, the builds, requirements, and build and test commands: `README.md`.
   - Scripts, workflows, rules and conventions for development: this file.
   - Don't copy text between these files; link to it. Report test results as they are, including known failures.

## Scripts

Scripts run with the bash 3.2 that ships with macOS (so no associative arrays or `mapfile`), and quote every path, since the repository may live in a folder with spaces.

| Script | Use it to |
| --- | --- |
| `apply-patches.sh [--through PATCH]` | Apply all patches, or those up to and including `PATCH` (a name such as `tabs`, `shell`, `webpage` or `remote`, the start of one, or a number such as `02`), to the clean submodule. The whole selection is preflighted in a private index first. |
| `reset-submodule.sh [--yes] [--clean-ignored]` | Return the submodule to the pinned commit. Local changes are stashed in the submodule first, and the recovery commands are printed. It asks for confirmation unless `--yes` is given, and refuses outside a terminal without it. |
| `workspace.sh [DIR]` | Create the patch workspace (default `.work/CotEditor`): the pinned commit plus one commit per patch, named after the patch file, holding the patch with its test part. |
| `export-patches.sh [DIR]` | Write `patches/*.patch` and their test parts, `patches/tests/*.patch`, from the workspace commits, then run `verify-patches.sh --workspace`. A commit's changes under `Tests/` go to the test part, all others to the patch; a test part that would be empty is removed. It refuses uncommitted changes, merges, and badly named or out-of-order commits. |
| `verify-patches.sh [--workspace DIR] [--build] [--test] [--keep]` | Apply every prefix of the series, each patch with its test part, to fresh clones and check that each patch is refused on upstream and on every prefix shorter than the one it follows (test parts are only applied with their patch, so they are not checked for this). `--workspace` compares the full series with the workspace's tree; `--build` builds the app of every prefix; `--test` also runs each prefix's focused tests. |
| `build.sh [--through PATCH] [--workspace [DIR] \| --checkout DIR] [--release] [--arch arm64\|x86_64\|both] [--test\|--test-all] [--adhoc]` | Build or test the app of a prefix. `--through` selects the last patch as `apply-patches.sh` does (default: every patch). The prefix is made from the patch files, or with `--workspace` from the workspace's commit of that patch (uncommitted changes are left out, with a warning), and checked out in `.build/Checkout`, which the scripts own: checking out another prefix rewrites only the files that differ, so switching prefixes recompiles only those. `--checkout DIR` builds a working tree as it is instead, for development. All builds share one derived-data folder, so run them one after another. `--test` runs the focused suites whose files the tree has; `--test-all` runs the whole plan. While `remote-fixture.sh` runs, its folder is passed to the tests (`TEST_RUNNER_COTEDITOR_REMOTE_FIXTURE`), which then also use the real servers. `--adhoc` signs without a team, passing `CODE_SIGN_ENTITLEMENTS_SUFFIX=-AdHoc` as upstream's CI does. It checks for the Metal Toolchain and summarizes errors and failed tests; the full log is in `.build/logs/`. Every build has one architecture: `--arch`, or this Mac's by default, and `both` builds the two one after the other. This Mac's is built alone (`-destination platform=macOS,arch=…` with `ONLY_ACTIVE_ARCH=YES`, since upstream's Release configuration builds every architecture otherwise). The other architecture is built for any Mac (`-destination generic/platform=macOS`), and the copy keeps only that architecture (`lipo -thin`; each architecture carries its own signature, so the copy still verifies); see the `ARCHS` pitfall below. Tests take only this Mac's architecture. A build is copied to `.build/Apps/<Debug\|Release>/`, named after the bundle identifier (`CotEditor-Tabs` for upstream's, otherwise the identifier's last component) followed by `-arm64` or `-x86_64`, replacing the previous copy of that app, and the copy's path is printed. The product in `DerivedData` stays `CotEditor.app`, which the test host path depends on. |
| `sync-strings.sh [--checkout DIR] [--no-build] [CATALOG...]` | Update the string catalogs the patches touch from the compiler's own output (`xcstringstool sync`), exactly as Xcode does in the IDE (default checkout: the workspace, which has every patch and so every string). |
| `check-signing.sh [--through PATCH] [--workspace [DIR] \| --checkout DIR] [--pty]` | Build an ad-hoc signed Release app of a prefix, as `build.sh` does, and check it: hardened runtime on, only this Mac's architecture, strict verification, and the App Sandbox on for the Tabs app but off, without iCloud, for every later app. `--pty` also runs the PTY tests, and for an app with remote files the tests that launch `ssh` against the fixture, in a test host re-signed with the hardened runtime and the ad-hoc entitlements. |
| `remote-fixture.sh start\|stop [DIR]` | Run or stop the local SFTP test servers (default `.build/remote-fixture`): the system's `sshd` as the current user on `127.0.0.1`, one SFTP-only and one without SFTP, with fresh keys and a client `ssh_config` of their own, and limits on pending connections raised so that tests signing in at once are never dropped. Its hosts also cover an unknown and a replaced host key, one whose known hosts file a test adds the key to, a jump host (the server without SFTP, which forwards to the SFTP server only), a host behind a jump host that has one of its own, a client key locked with a passphrase, a third server that runs a shell with a terminal (as `/bin/sh`, whatever the account's shell is), and a port reserved for a relay that tests run and cut (`RemoteFixtureRelay`); its data has a read-only folder and a folder tree for browsing, with nested, empty, unreadable and large folders and links. See "Remote tests" below. |

## Workflows

### Set up

After cloning as described in the README:

```sh
scripts/workspace.sh                         # .work/CotEditor, branch "patches"
scripts/build.sh --checkout .work/CotEditor --test
```

`--checkout .work/CotEditor` builds and tests the whole series with your uncommitted changes. To try a shorter prefix of your work, commit it and use `--workspace --through PATCH`.

### Change a patch

Commit the change into the commit of the patch it belongs to, then export:

```sh
cd .work/CotEditor
git commit -a --fixup=<commit of 01-tabs>
git rebase --autosquash "$(git -C ../.. rev-parse :CotEditor)"   # the pinned commit
cd ../..
scripts/sync-strings.sh --no-build             # only if user-facing strings changed; commit the result too
scripts/export-patches.sh
scripts/verify-patches.sh --workspace .work/CotEditor --test
```

If a rebase conflicts in a later patch, the change altered something that patch depends on. Resolve it there; don't work around it in the earlier patch.

### Add a patch

1. Add a commit named `05-name` (increasing two-digit numbers, then a short lower-case name with hyphens, which `--through` also accepts) at the end of the workspace history, then export. For a reserved number such as `03`, insert the commit before the later patches instead: commit it on top of the patch it follows, then move the later commits onto it with `git rebase --onto`, resolving conflicts in those later patches.
2. Write `docs/05-name.md`, following the existing patch documents, and add it to the list and a column to the table in `docs/README.md`.
3. Describe what users get in the README's Features section, and add a row to its apps table.
4. Give the new app its own bundle identifier in `Configurations/CotEditor.xcconfig` (see rule 5), and add its suites to the list of focused tests in `build.sh`.

### Strings

- Patch 1's strings live in the upstream tables (`Document`, `WindowSettings`). Non-English values are added marked `needs_review`, and set to `translated` once someone has reviewed them.
- Patch 2's strings live in `CotEditor/Localizables/Terminal.xcstrings`, patch 3's in `WebPages.xcstrings`, English only.
- Run `scripts/sync-strings.sh` after adding or changing `String(localized:...)` calls.
  - **Catalogs that exist upstream:** it only splices newly added entries into the original text, and warns about entries whose English text or comment changed; update those by hand. `xcstringstool` itself would re-sort every entry's languages and rewrite thousands of upstream lines.
  - **Catalogs added by a patch:** it syncs them in place, with stale marking.
  - **Translations:** new entries arrive in English only. For patch 1, add translations marked `needs_review`, with languages in the catalog's order (`… uk, zh-Hans, zh-Hant, zh-HK`). For a `String(localized:)` interpolation, the catalog placeholder follows the Swift type: `Int` gives `%lld`, `Int32` gives `%d`, and strings give `%@`.

### Upgrade the pinned upstream commit

```sh
git -C CotEditor fetch origin && git -C CotEditor checkout --detach <new commit>
git add CotEditor                                   # stage the new gitlink; the scripts read the staged one
git -C .work/CotEditor fetch "$PWD/CotEditor" <new commit>
git -C .work/CotEditor rebase --onto <new commit> <old commit> patches
# resolve conflicts patch by patch; the project file (project.pbxproj) is the usual one
scripts/export-patches.sh
scripts/verify-patches.sh --workspace .work/CotEditor --test
scripts/build.sh --checkout .work/CotEditor --test-all
```

Then update the pinned commit in `README.md` and the evidence in `docs/`, and commit them together with the gitlink and the patches.

### Check signing after entitlement or build-setting changes

```sh
scripts/check-signing.sh --workspace --through tabs
scripts/check-signing.sh --workspace --through shell --pty
scripts/check-signing.sh --workspace --through webpage
scripts/remote-fixture.sh start
scripts/check-signing.sh --workspace --through remote --pty
```

This is not a distribution check: a Developer ID signature and notarization need a team identity and have not been done.

### Clean up

`scripts/reset-submodule.sh` for the submodule. Delete `.build/` freely: it holds about 5 GB of build output and the scripts' own checkout. `.work/` holds the workspace, so export first.

## Requirements

Those in the README, plus:

- git 2.44 or later, for the non-interactive `rebase --autosquash` above.
- Disk space for each separate derived-data folder, which costs as much as a build again. The scripts share one in `.build/` for that reason.

## Conventions for code and tests

- **Code style.** Match the surrounding CotEditor code: indentation, blank lines, `self.` prefixes, doc comments, and the license header used by new files in this project. SwiftLint runs during the build. Keep files you touch free of new warnings; some existing patch-1 lines already have warnings.
- **Comments.** Write for someone reading the code months later without context. Explain why, not what the code does. Don't refer to changes, requests, alternatives, dates, tickets or people; describe the code as if it had always been this way. The same goes for the documentation.
- **Punctuation.** Don't use em dashes or en dashes in code, comments, strings or documentation.
- **Global state in tests.** Tests that change the global file-tabs preference, `TerminalSession.defaultEngineFactory`, `TerminalPrompts.current`, `TerminalNotifications.current`, `WebPagePrompts.current`, `RemoteEnvironment.current` or `RemoteTermination.isInProgress`, or open remote folder windows (whose registry is app-wide), must live in the serialized `DirectoryTabTests` suite, or an extension of it (see `DirectoryTabTests+Terminal.swift`, `DirectoryTabTests+WebPage.swift`, `DirectoryTabTests+Remote.swift` and `DirectoryTabTests+RemoteFolders.swift`). Swift Testing runs separate suites in parallel, and tests within a suite in parallel too unless it is serialized.
- **Remote documents carry their services.** A `RemoteDocument` keeps the `RemoteEnvironment` (connection pool, prompts, recovery folder, timing) it was created with. Tests of remote documents create a `RemoteTestBed`, which has its own fake server, scripted prompts, recovery folder and endpoint, so they need no global state. The endpoint is unique per test bed because the registry of open remote files is app-wide.
- **Close what a test opens.** A document left open keeps autosaving; if its recovery folder is gone, AppKit shows alerts in the test host. `RemoteTestBed.tearDown()` closes every document the bed opened (`track(_:)` for others) before removing the folder.
- **Deterministic waits.** Don't rely on timing. Give the code a seam and control it from the test: `approveMemberClose` for member close approval, fake engines and scripted prompts for terminals. Holding an NSDocument's file access does not work for this: its close-time autosave waits for it synchronously on the main thread.
- **PTY tests** (`TerminalPTYTests`):
  - Use `/bin/sh -c` or `zsh -f` with a fixed environment, never the developer's shell configuration.
  - Bound every wait, and shut engines down even when an expectation fails.
  - Wait for the expected output, not just the exit: SwiftTerm can report the exit before the last output is drawn.
  - Read the screen through `SwiftTermEngine.bufferText`. SwiftTerm's `getBufferAsData()` drops characters made of several scalars, such as NFD file names.
- **Tabs that are not files** are tested through the contract with `FakeTabItem` and `FakeTabKind` (`DirectoryTabTests+Items.swift`). Give a directory its kinds through `tabKinds` rather than changing `DirectoryTabKind.registered`.
- **Webpage tests** load pages only from `WebPageTestServer`, a loopback HTTP server that counts requests per path and method; assert on those counts to prove that something was or was not sent. Never load a public website; a refused destination is refused before WebKit makes a request, so a test may name one.
- **Remote tests** against a real server run only when `scripts/remote-fixture.sh start` has been run; they are skipped, and reported as skipped, otherwise. They connect only through the fixture's `ssh_config` (`RemoteSSHCommand.TestOverrides`), never with the developer's own configuration, keys or agent. The fake SFTP server in `RemoteTestSupport.swift` covers everything a single-user fixture cannot: other owners, exact failures at each request, lost replies, pauses. It keys files by their paths' bytes, like a server, so names that differ only in Unicode normalization are two files there too; keep it that way. It also lists folders, in batches of a size the test sets, and can leave out types, add raw names such as ones that are not UTF-8, and never end a listing. It creates, removes and renames folders as OpenSSH does, refusing a rename onto an existing item unless the test makes it replace one, with a umask the test sets (none by default, so that the modes a save sets stay exact).
- **Questions of `ssh`** are answered by a `RemoteAskpass` server. `RemoteSSHCommand.TestOverrides` gives each test one of its own, which nobody answers unless the test sets an answerer, so `ssh` runs in batch mode; never use the app's (`RemoteAskpass.shared`), which the test host's launch sets up to ask with alerts.
- **Folder trees** are tested with `ScriptedTreeSource` (`RemoteDirectoryTreeTests.swift`), whose listings and resolutions the test sets and can hold until it lets them go. A held reply ignores cancellation, as a reply already on its way would, so that only the tree's own generation checks can drop it.
- **Directories without a local folder** are tested through the root contract with `FakeDirectoryRoot` (`DirectoryTabTests+Root.swift`), as tabs that are not files are with `FakeTabItem`.
- **Prove that a new test catches the bug.** After adding a test for a bug or safety property, temporarily disable the code it protects and confirm the test fails. Record the check in the mutation table of that patch's document in `docs/`. If you break process cleanup this way, kill any leftover test shells afterwards.

## Pitfalls

- **Swift Testing IDs:** `-only-testing` needs the trailing parentheses for a single test, for example `-only-testing:"Tests/TerminalPTYTests/runsInItsOwnDirectoryWithUnicode()"`.
- **Don't pipe `xcodebuild` into `head`:** closing the pipe kills the build. Send it to a log (as `build.sh` does) and read the log.
- **Plugin validation:** `-skipPackagePluginValidation` is needed for SwiftLint's and SwiftTerm's build plugins.
- **Don't pass `ARCHS` on the command line, or a destination with the other architecture:** they also apply to the build plugins, which then cannot run on a Mac without Rosetta ("Bad CPU type in executable" from SwiftTerm's build information generator). `build.sh --arch` with the other architecture thins a build for any Mac instead.
- **SwiftTerm's source** at the pinned revision is in `.build/DerivedData/SourcePackages/checkouts/SwiftTerm` after a build. Read the actual APIs there before relying on them. For example, its `LocalProcess.terminate()` never reaps the shell, which is why `TerminalProcessReaper` exists.
- **Locale in tests.** Tests run in the developer's locale (for example `en_NL`, which groups thousands with a period). Compare formatted numbers with the value's own `formatted()` rather than with US-style text; patch 1 fixes upstream's `EditorCounterTests.formatCountValue()` this way.
- **Test host signing:** Xcode signs test hosts without the hardened runtime. Use `check-signing.sh --pty` when that matters.
- **Remembered layouts in tests.** Tests share the app's preferences, including remembered window layouts such as the split-view divider (`NSSplitView Subview Frames DirectoryWindowContentSplitView`). Layout tests must set the geometry they depend on rather than trust what earlier runs left behind.
- **Measuring a view that is moved by `.offset`:** measure outside the offset, or the measurement feeds back into the offset and the view jitters. Tests cannot see where SwiftUI draws a moved view, so check such drags by hand. See "Dragging to reorder" in [`docs/01-tabs.md`](docs/01-tabs.md).
- **Restorable state in tests:** a helper that encodes a document's restorable state must wait for the background queue it passes before finishing the archive (`queue.waitUntilAllOperationsAreFinished()`), as AppKit does. For documents without a file, AppKit adds work to that queue, and an archive finished early makes it throw and crash the test host.
- **Remote paths are compared byte by byte** (`RemotePath.isSame`). Swift's `String` equality treats composed and decomposed characters as equal, but a server's file system generally does not.
- **Subclassing `Document`:** a private method of a non-final class stays in its dispatch table, and a subclass in another file then fails to link against it. Mark such a method `final`.
- **`ssh` and `sshd` refuse key paths with spaces**, even quoted. The fixture's configurations reach its folder through a link in the temporary folder.
- **Undo groups never close in tests.** The test host has no event loop to end them, so a change made through the undo manager, such as `changeEncoding(to:)`, does not mark a document as edited there. Test what depends on the change itself instead, such as a remote document's recovery record.
- **Remote operations carry a control.** A save or open runs with `RemoteOperationControl.current`; tests that cancel or extend one wrap the call in `RemoteOperationControl.$current.withValue(_:)`.
- **The test host is not the active app**, so no window is key or main. Code that asks whether a window is the active one must also accept the frontmost window while the app has no main window (see `WebPageViewController.isActiveWindow`).
- **`WKSecurityOrigin.host` brackets IPv6 addresses already.** Don't bracket them again when showing an origin.
- **The file browser opens a selected row's file on a later turn of the main queue**, including a row it selected itself because a file was selected. Anything that selects another tab right after selecting a file relies on the selection-generation check in `outlineViewSelectionDidChange`.
- **Access control lists override modes.** The repository's folder may pass an inherited ACL on to everything created in it, which grants what `chmod` denies. The fixture removes it (`chmod -N`) where a mode must deny access, as for its read-only and unreadable folders.
- **APFS cannot hold two names that differ only in Unicode normalization** in one folder, so such a pair exists only on the fake server; the fixture has one decomposed name.
- **A directory URL's path ends with a slash** (`URL.path(percentEncoded:)` with `.isDirectory`), so a remote path built from it gets `//`, which the server accepts but byte-wise comparisons do not.
- **Updating an outline view from a model it drives:** an `NSOutlineView` expansion calls its delegate, which can change the model, which must not reload rows inside that call. The remote sidebar applies tree changes on a later turn of the main queue.
- **Quit the app of the same build before testing.** The test host has the app's bundle identifier, so launching or quitting that app from the Finder while tests run can reach the test host, which then exits with status 0 in the middle of the run ("The test runner exited with code 0 before finishing").
- **An untitled document at launch.** Depending on the app's settings and the Mac's (upstream opens one when `applicationShouldOpenUntitledFile` is called, which its comment says happens when iCloud Drive is off), the test host may open an untitled document at launch. Its window is then the frontmost one, which matters to code that accepts the frontmost window while the app is not active; the webpage test helper closes it.
- **A modal alert in the test host stops every test.** An alert run with `runModal()` on the main actor waits for nobody, and every main-actor test of the run times out behind it. A test must never reach the app's own prompts, such as through `RemoteAskpass.shared`.
- **Hosted SwiftUI views and layout:** an `NSHostingView` inside AppKit layout adds required constraints for its content's minimum and maximum size by default. Set `sizingOptions` explicitly (see `TerminalTabViewController` and upstream's `ContentViewController.hostingController(rootView:)`), or an empty or fixed-size SwiftUI view can lock the split view panes.
