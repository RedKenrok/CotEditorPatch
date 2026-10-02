# Patch 2: shell tabs

`patches/02-shell.patch` adds **shell tabs beside file tabs in folder windows**, and makes the app the unsandboxed `CotEditor-Shell` app. It is the delta from the exact exported state of [patch 1](01-tabs.md) and does not apply to plain upstream. The Tabs app is built from patch 1 alone, so it never contains terminal code.

See [the overview](README.md) for how this patch divides the work with patch 1.

## Changes to shared code

- Terminal sources live in `CotEditor/Sources/Terminal/`, with names starting with `Terminal` or `SwiftTerm`.
- Terminals are a kind of tab through patch 1's [contract for tabs that are not files](01-tabs.md#tabs-that-are-not-files): `TerminalSession` conforms to `DirectoryTabItem`, and `DirectoryTabKind.terminal` asks once for the running terminals of a closing window, restores placeholders and adds **New Shell** to the **+** menu. The patch adds no branch to patch 1's tab state, content host, close handling or archive.
- Shared files are edited directly, only where the feature is registered or has commands: `.terminal` in `DirectoryTabKind.registered`, menus, quit consent, the file browser's Open Shell Here, the settings pane and toggle, and the license list. Of the existing lines, the patch changes 4: the registered kinds, the settings toggle's binding, and the license list.

## Build configuration and dependency

- **No separate scheme or configuration.** The patch changes upstream's own `CotEditor` scheme and its Debug and Release configurations, so the app built from patches 1 and 2 is the Shell app.
- **Identity.** `Configurations/CotEditor.xcconfig` sets the bundle identifier `local.coteditor-tabs.CotEditor-Shell`, so a development install never replaces a regular CotEditor or shares its preferences and saved window state. The project file no longer sets upstream's identifier for the app target, since a target setting would override the xcconfig; upstream's Sparkle configurations keep theirs. The product and bundle name stay `CotEditor`, which keeps the test host path and module name intact. Anyone distributing the app must use an identifier in a domain they control, and must respect CotEditor's name under the Apache 2.0 trademark clause. No Mac App Store support is intended.
- **Entitlements.** Upstream's `CotEditor.entitlements` and `CotEditor-AdHoc.entitlements` lose the App Sandbox, iCloud and the sandbox-only file and print entitlements. They keep the hardened-process (enhanced security) entitlements, and the target keeps `ENABLE_HARDENED_RUNTIME = YES`. The ad-hoc file, which `build.sh --adhoc` selects with upstream's `CODE_SIGN_ENTITLEMENTS_SUFFIX=-AdHoc`, keeps upstream's `cs.disable-library-validation`, because library validation cannot succeed without a team ID, and uses enhanced-security version 2 like the other file.
- **Upstream's `CotEditor-Sparkle` scheme** is left as upstream has it. This project does not build it.
- **SwiftTerm.** Pinned to exactly **1.20.0**, revision `5d14406844143538cd8f8851d2d8a67c1fe443e5` (MIT), recorded in `Package.resolved`. Its license notice is listed in About > Licenses. The APIs used were read at that revision: `LocalProcessTerminalView`, its delegates, `LocalProcess` and `PseudoTerminalHelpers.fork`.
- **Metal Toolchain.** SwiftTerm compiles a Metal shader, which needs Xcode's optional Metal Toolchain component.

## Session model and adapter

- `TerminalSession` (main actor, observable) is the tab's model. It holds the stable ID, a generated title (`Terminal`, `Terminal 2`, and so on, unique within the window and reused once freed), an optional user name, the starting folder, an optional shell path and its lifecycle: `inactive`, `running`, `exited(status)`, `failed(error)` or `closed`. A session never uses `DataDocument`, file URLs or edited markers.
- The title is the user's name, then the sanitized shell title, then the generated title. Titles from the shell are untrusted, so control characters are removed and the length is bounded.
- `TerminalEngine` is the only interface to the emulator. `SwiftTermEngine` wraps one `LocalProcessTerminalView` and its PTY for the life of a process. Switching tabs only moves the view in and out of the window. A restart replaces the engine, so a new shell never inherits old output, and callbacks from a replaced or closed engine are ignored. Tests inject a fake engine.
- The tab's status view (a restored placeholder or a launch error) is a SwiftUI hosting view that reports only its intrinsic size, with low horizontal priorities. By default a hosting view turns its content's minimum and maximum size into required constraints; the empty status of a running terminal has a maximum width of zero, which would squeeze the whole content pane to its minimum and lock the divider.
- `TerminalContainerView` forwards only usable sizes to the terminal view, so a hidden or transient layout never sends a zero-sized resize to the program.
- The container also centers the character grid. SwiftTerm fits whole cells from the top leading corner and always keeps a strip beside the grid for its scroller (17 pt, even while the overlay scroller is hidden), so on its own it leaves a wide trailing gap and a bottom gap of up to one row. The container instead sizes the terminal view to the largest whole grid that leaves at least the scroller's width on every edge, and splits the rest evenly: the scroller's strip lies inside the trailing margin, and the grid's top leading corner is on the pixel grid. The terminal view is half a pixel larger than the grid, so SwiftTerm's own division of its frame by the cell size cannot lose a row or column to rounding. The cell size is read back from SwiftTerm's `getOptimalFrameSize()`, since SwiftTerm snaps it to the pixel grid internally and does not expose it. The margins are painted in the terminal's background color, and a click in them focuses the terminal.
- Scrollback is bounded to 10,000 lines. The bell sounds at most once every 200 ms, since output such as a binary file can hold thousands of bell characters in a row. Option is not used as Meta, so keyboard layouts that compose characters with Option keep working. Control-key combinations go to the shell even when a menu item is bound to them.
- **Word and line editing keys.** SwiftTerm sends none of the Mac's editing shortcuts usefully: with Option not acting as Meta, it ignores Cocoa's word commands and sends ⌘← and ⌘→ as word movement, and while a program uses the kitty keyboard protocol (as many newer full-screen programs do), it sends ⌥← as a plain ← and ⌘← as Super-←, which programs do not bind. One key event monitor, shared by every terminal, sees the keys before the main menu and SwiftTerm (whose `keyDown(with:)` is not `open`, and which encodes kitty keys without passing them on) and hands them to the terminal view that is its window's first responder (`TerminalHostView.handleKeyDown(_:)`). That view sends what shells and line editors expect, as iTerm's natural text editing does: ESC b and ESC f for ⌥← and ⌥→, ⌃A and ⌃E for ⌘← and ⌘→, ⌃W and ⌃U for ⌥⌫ and ⌘⌫, ESC d and ⌃K for ⌥⌦ and ⌘⌦. The bytes are the same under every keyboard protocol, since programs that ask for the kitty protocol still read the legacy bytes that most terminals send. When a program has switched the cursor keys to application mode, as vim does, ⌘← and ⌘→ send Home and End (ESC O H, ESC O F) instead, because ⌃A has other meanings there. With Shift or Control added, or while an input method is composing text, the keys keep SwiftTerm's behavior.

### Policy on terminal output

SwiftTerm makes the view its own delegate, and would let output write to and read the general pasteboard (OSC 52) and open any URL or file. The engine installs a proxy delegate that:

- refuses clipboard reads and writes, and inline file transfers;
- on a user click, opens only `http` and `https` links that have a host (`SwiftTermEngine.openableURL(for:)`).

Bracketed paste is SwiftTerm's own.

### Notifications from programs

Programs ask for a desktop notification with OSC 777 (`ESC ] 777 ; notify ; title ; body BEL`, or ending with ST), as coding agents do when they finish; the pi coding agent's `notify` extension sends it on its own when `TERM_PROGRAM` is `CotEditorPatch`. SwiftTerm decodes the sequence, but hands it to a `TerminalDelegate` method that its view implements as doing nothing and that `TerminalViewDelegate` has no counterpart for, so the engine registers its own handler for code 777 (`registerOscHandler`, which SwiftTerm consults before its built-in ones). From there:

- **Decoding** (`TerminalNotification(osc777:)`). Only the `notify` command in UTF-8 is accepted. The body is everything after the second separator, so it may contain semicolons. The text is untrusted, so controls and line breaks become spaces, format characters (including bidirectional overrides) are removed, whitespace is collapsed, and the title and body are bounded to 120 and 400 characters. A notification with neither title nor body is ignored.
- **Rate.** A session forwards at most one notification per second, so a program that prints the sequence in a loop cannot flood Notification Center. Notifications from a replaced engine or a closed tab are ignored, like its other callbacks.
- **When it shows** (`DirectoryDocument.postTerminalNotification`). Only while the user is not looking at the terminal: the app is not active, or another tab is selected, or the window is not the key or main window (or, with no main window, the frontmost one), or it is hidden or minimized. **Show notifications from programs** in the Shell settings pane (on by default) turns them off.
- **Delivery** (`TerminalUserNotifications`, through the replaceable `TerminalNotifications.current`). Notification Center asks for permission the first time a program notifies, not at launch. The program's title is the notification's title; the subtitle names the tab and the window's folder, since the text alone could claim to come from anything. Each tab has at most one notification there: a newer one replaces the older (the request identifier is the session ID). It is shown as a banner with the default sound, also while the app is in front.
- **Clicking it** selects the tab, brings its window forward and focuses the terminal (`TerminalNotifications.reveal(sessionID:)`). The notification center's delegate is set in `applicationWillFinishLaunching`, so a click on a notification of an earlier launch is handled too; one whose tab is gone does nothing.

The sequence travels in the output like any other, so it works from a shell on a server as well, and inside tmux with `allow-passthrough` on, if the program wraps it in tmux's passthrough. OSC 9 and kitty's OSC 99 are not handled.

## Shell launch and lifecycle

- **Shell.** The shell is the account's login shell from `getpwuid_r`, not `$SHELL`, which a Finder-launched app inherits from launchd. A restored or configured shell is validated first: it must be an absolute path to an executable file. The fallback order is the requested shell, then the account shell, then `/bin/zsh`. If none can run, the tab shows the error. The shell starts as a login shell (`argv[0]` prefixed with `-`), with no arguments.
- **Descriptors.** SwiftTerm forks with `forkpty` and closes nothing in the child, so the shell would inherit every descriptor of the app that is not marked to close on exec: other terminals' PTYs, and the pipes of processes the app runs. Before each start, the engine marks every descriptor above the standard ones `FD_CLOEXEC`, and after it the new PTY too. Terminals start one at a time on the main actor, so no shell is forked before its predecessor's PTY is marked. The app never executes a program in its own place, and the programs it launches get their standard descriptors set up explicitly, so the mark changes nothing else.
- **Working directory.** It is passed to SwiftTerm's per-process launch, where the child calls `chdir` after `forkpty`. The app's own directory never changes, and folder names never pass through a command line or typed input. The folder is validated before the spawn; a missing one shows the error with **Choose Folder…**.
- **Environment.** The child's environment is an allowlist: `HOME`, `USER`, `LOGNAME`, `TMPDIR`, `PATH`, `SSH_AUTH_SOCK`, `__CF_USER_TEXT_ENCODING` and locale variables. Added to it are `SHELL`, `TERM=xterm-256color`, `COLORTERM=truecolor`, `TERM_PROGRAM=CotEditorPatch` and `TERM_PROGRAM_VERSION`. A default `PATH` and a UTF-8 `LANG` are supplied when missing. Dynamic-linker, XPC, debugger and launch variables do not leak into the shell. No project script is ever run; the shell's normal startup files run as usual.
- **Failure.** A failed fork or validation shows the error with **Try Again**, **Choose Folder…** and **Close Tab**. A retry is a new process, and nothing is replayed.
- **Exit.** A shell that exits on its own, for example after `exit`, closes its tab without asking, since nothing runs any more, and the neighbor takes over the selection. The tab closes on the next turn of the main queue, not inside SwiftTerm's exit callback, and only if it still exists by then, so an exit while the tab's close prompt is open closes it exactly once.
- **Natural exit.** SwiftTerm checks for the shell's exit once, without waiting, when the exit notification arrives, and reports 0 when it found nothing to reap, which is also a clean exit's status. The notification can come just before the shell can be reaped. For a reported 0, the engine therefore checks whether the shell is still there, identified by its PID and its start time (`TerminalProcessIdentity`, from `sysctl`, which also describes a zombie), and if so reaps it and reports its real status on a later turn. A PID that SwiftTerm reaped and another process reused has another start time, and is left alone.
- **Shutdown** (`TerminalProcessReaper`). SwiftTerm's `terminate()` never reaps the shell, and after a natural exit it would signal the old, possibly reused, PID. The engine therefore drives shutdown itself:
  1. Send SIGHUP and SIGCONT to the shell's process group and to the terminal's foreground group.
  2. Close the PTY.
  3. Wait up to 2 seconds for the shell to exit, reaping it.
  4. If it is still running, send SIGKILL to those groups, then reap.

  The wait sleeps between checks rather than blocking a thread, so any number of sessions can stop at once without holding up the concurrency thread pool. After SIGKILL it keeps checking, less and less often, until the shell is reaped, since a process in an uninterruptible wait can only be reaped once that wait ends. The waits in progress are registered, and quitting finishes them (see below).

  Signals only target groups that are provably owned. The shell leads a new session, and while it is unreaped its PID (the group and session ID) cannot be reused. The foreground group is killed only if one of its members belongs to that session; its ID is its leader's PID, and the leader may have exited while other members still run, as in a pipeline whose first command ended. Every check for the exit and every signal happens under the reaper's lock, so a quit and a background wait on the same shell can never signal after its reap. An exited shell is never signaled again. Jobs the user detached (`nohup`, `disown`, `setsid`) may outlive the terminal by design. A running session disables sudden termination, so the system cannot kill the app without asking.
- **Forgotten sessions.** A session or engine released without being closed still stops its process in its `deinit`, and a session gives back its block on sudden termination. Every current owner closes them; this only keeps a future mistake from leaving a shell running.

## Commands, selection and routing

- **Commands.** **File > New Shell Tab**, **File > Rename Shell Tab…**, **New Shell** in patch 1's **+** menu, **Rename…** in a shell tab's context menu, and **Open Shell Here** in the file browser, which uses the clicked folder or the clicked file's parent. The commands are only available in folder windows; there is no standalone terminal window.
- **A folder that is not on this Mac.** A window whose folder has no file URL (patch 1's [root](01-tabs.md#folders-that-are-not-on-this-mac)) still offers **New Shell** and New Shell Tab, which start a shell on this Mac in the home folder (`localTerminalDirectory`); the tab's tooltip names that folder, so the shell is not mistaken for one in the window's folder. A root that is `TerminalLaunchProviding` also runs terminals where it says: it names a second **+** menu item (`terminalMenuItemTitle`, `terminalMenuItemSystemImage`), and that item and `DirectoryDocument.newRootTerminalTab(_:)`, for a menu item the root's patch adds, ask the root for a `TerminalLauncher`, with the location for the tooltip and the launch configuration of each start. A failure to prepare one opens no tab, not even a local shell in its place, and shows why. A launcher's terminal is not archived, since only the launcher could start it again, and one whose process ends with a status other than 0 keeps its tab and output, with **Start New Session** and **Close Tab**.
- **No default shortcut** for New Shell Tab: the usual ⌃⇧\` is already CotEditor's Move Focus to Previous Editor. The item exists before key bindings are read, so users can assign one.
- **Tabs turned off.** New Shell Tab offers **Enable Tabs and Open Shell** (Cancel does nothing), and explains that the setting applies to all folder windows. It then uses patch 1's preference transition.
- **Selection.** Selecting a terminal, through patch 1's `selectTabItem(_:)`, detaches the current file from the window (`windowController.fileDocument` and `currentDocument` become nil) and hosts the terminal's controller; the outgoing editor stays in patch 1's editor cache. `activeFileDocument` is nil, so save, encoding, line endings, print, inspector and status bar content, and editor transforms cannot reach a hidden file. The file browser keeps the last file highlighted as context. Opening that file, or selecting its tab, attaches it again with its editor state. Keyboard focus moves into the terminal.
- **Titles.** The window subtitle shows the terminal's title. The tab's tooltip names the starting folder, explicitly not the shell's current one, which is not tracked.
- **Moving.** Shell tabs reorder like file tabs, but do not move to a window of their own.
- **Routing.** Patch 1's tab commands apply unchanged: ⌘W closes the selected tab (here a terminal, with its confirmation), File > Close Window closes the window, and Next/Previous Tab and ⌘1 to ⌘9 walk the mixed tabs in shared order. Copy, Paste and Select All act on the focused terminal through the responder chain.

## Close, quit and preference transitions

- **Closing a tab.** Closing a failed or inactive terminal is immediate; an exited one has already closed itself. Closing a running one asks **Close Shell / Cancel**. Canceling sends no signal. Repeated requests for the same tab, and requests during a window-close review, are refused.
- **Closing a window, and Close All.** Patch 1's `canCloseMembers` asks `DirectoryTabKind.terminal` once for all running terminals of the window, then collects the dirty-file approvals. Terminals are stopped only in `close()`, after every approval. A pending terminal close blocks the window close, as a pending file close does.
- **Quit.** `DocumentController.reviewUnsavedDocuments` asks for terminal consent before any document is reviewed. If a later dirty-file prompt is canceled, the consent is revoked and every terminal keeps running. `applicationShouldTerminate` covers terminations that skip the review. `applicationWillTerminate` stops all sessions with one shared deadline of 1 second before forcing owned groups, including those of tabs closed shortly before whose background wait is still in its grace period. The wait after forcing is bounded to 1 second in total, so a process in an uninterruptible wait cannot keep the app from exiting. A termination that cannot be canceled (a forced logout) does not ask, but still stops the processes.
- **Turning tabs off.** In Settings, turning tabs off goes through `TerminalTabsPreference`. If any terminal exists in any window, it asks once, noting when work is running. Only after approval does it close every terminal, placeholders included, and turn tabs off. Cancel leaves the preference and every terminal unchanged. Patch 1's observer still ends terminals if the preference changes some other way (such as `defaults write`), since they cannot be shown without tabs.

## Terminal settings

A **Terminal** pane in Settings chooses the terminal's colors.

- **Theme.** "Same as Editor" (the default) follows the editor's theme exactly, including its light and dark switching. Any CotEditor theme can be chosen instead; it switches to its light or dark variant with the appearance, like the editor's theme, unless themes are pinned to their appearance. A theme that no longer exists falls back to the editor's. Text, background, cursor and selection come from the theme. Dynamic system colors, such as a system selection color, are resolved to fixed sRGB values in the terminal's own appearance.
- **Program colors.** Programs such as `ls` or `git` choose from 16 ANSI colors, which CotEditor themes do not define. With **Match program colors to the theme** on (the default), each of red, green, yellow, blue, magenta and cyan takes the theme's syntax color closest in hue (within 35°). The color must be saturated and readable on the background (a contrast ratio of at least 3:1); otherwise the standard color is kept, so red still means an error. Black, white and their bright variants are mixed from the background and text; bright black is the comment color when readable. Bright variants are lighter on dark backgrounds and unchanged on light ones. With the toggle off, the standard palette (Terminal.app's, SwiftTerm's default) is used.
- **Live updates.** Terminals update at once when the terminal theme, the toggle, the editor theme, pinning or the document appearance changes, when a theme file is edited, and when the system switches between light and dark. The pane shows a preview of the resulting colors.
- **Font.** The terminal uses the system monospaced font.
- **Notifications.** **Show notifications from programs** (on by default) lets programs show desktop notifications; see [Notifications from programs](#notifications-from-programs).

## Restoration

- Terminal entries are written into patch 1's versioned archive (still version 1) under kind `terminal`, in the shared tab order. Each has its ID, the user's name, the shell path, the starting folder as a plain bookmark (the build is unsandboxed) and the folder path as a fallback. Making a bookmark touches the file system, which can be slow for a folder on a network volume, so each session makes its folder's bookmark once and makes it again only when the starting folder changes. The selected ID covers terminals. Patch 1's decoder hands the entries to this patch as foreign entries and skips them in a file-only build, so every build reads the same archive.
- The order of all tabs, `arrange(by:)` and the dispatch by kind are patch 1's; this patch gives each terminal's fields and recreates its placeholders through `DirectoryTabKind.terminal`.
- Output, commands, environment and clipboard contents are never archived.
- Decoding treats the archive as untrusted input. Invalid or duplicate IDs are dropped, titles are sanitized, and relative shell paths are ignored. A folder whose bookmark no longer resolves keeps its saved path, so the tab can offer repair.
- Terminals come back as **inactive placeholders**, including a selected one. The placeholder explains that processes and output are not restored and names the folder a new session starts in. It offers **Start New Session** (or **Choose Folder…** if the folder is gone) and **Close Tab**. No shell starts during restoration.
- Files reopen asynchronously, as in patch 1, and are put back into the archived order as they arrive.

## Strings

The new strings are in `CotEditor/Localizables/Terminal.xcstrings`, in English only. Other languages fall back to English. No translations are claimed.

## Tests

- `TerminalSessionTests` uses a fake engine for the session lifecycle (start, exit, restart, exactly-once close, late callbacks from a replaced engine, launch failures, a session released without closing), titles, wait-status decoding, shell resolution, the environment allowlist, folder validation, the link decision, notification decoding (separators in the body, other commands, empty text, invalid UTF-8, controls and bidirectional overrides, length bounds) and the session's rate limit, the archive's mixed order (through patch 1's archive) and rejection of damaged entries, and the folder bookmark made once per starting folder.
- `TerminalColorsTests` covers the program-color mapping, the readability filter, bright variants on light themes, the standard palette, and theme selection including pinned appearance.
- `DirectoryTabTests+Terminal` extends patch 1's serialized suite: a window without a local folder starting local terminals in the home folder (with patch 1's fake root), and a root's own terminals beside them, shared tab order and selection, hosting no file while a terminal is selected, focus, titles, every close path with its consent, shells exiting, preference transitions, quitting (including a real session of a tab closed just before), restoration as placeholders, reordering and reconciling, and notifications: posted only while the terminal is not in front or the app is not active, not after the setting is turned off or the tab closed, and a click selecting the tab. A layout test covers every status-view state with fake and real terminal views.
- `TerminalPTYTests` runs real shells. It covers: the working directory with a folder name containing shell syntax and non-ASCII (NFD) characters; Unicode output and copy; separate concurrent sessions and environments; resize reaching the PTY; exit codes, signals and exec failure (127); stopping an interactive shell's foreground job; forced stop of a session that ignores hangup, and of a foreground job whose group leader already exited; many sessions stopping at once leaving the thread pool free; an engine released without shutdown stopping its shell; PTY descriptor release after both a closed and an exited session, and the exited shell being reaped; no other terminal's PTY and no pipe of the app reaching a new shell; collecting the exit status of a shell not reaped yet, and leaving a process with a reused PID alone; a flood of bell characters sounding once; bracketed multiline paste; Control keys reaching the shell ahead of a menu item bound to ⌃C (in a window, asked the way AppKit asks the key window before the main menu); the bytes ⌥←, ⌥→, ⌘←, ⌘→, ⌥⌫, ⌘⌫, ⌥⌦ and ⌘⌦ send, in normal and application cursor mode and under the kitty keyboard protocol, and those keys staying with SwiftTerm with Shift added or with another view focused; degenerate container sizes and a detached view never resizing the PTY; clipboard escape sequences in both directions leaving the clipboard untouched with no reply; and OSC 777 notifications, ended with BEL or ST, reaching the engine from a real shell, with other OSC 777 commands ignored.

## Evidence

Environment: Xcode 27.0 (27A266a), Swift 6.4, macOS 27.0 (Darwin 27.0.0) on arm64, Metal Toolchain 27A266a installed, locale `en_NL`.

- **Focused tests.** `scripts/verify-patches.sh --workspace .work/CotEditor --test` passed 118 tests in 6 suites after patches 1 and 2, the PTY tests included.
- **Notifications from programs.** `scripts/verify-patches.sh --workspace .work/CotEditor --test` passed 125 tests in 6 suites after patches 1 and 2, and 368 tests in 19 suites with every patch, the PTY tests included. Notification Center itself (the permission prompt, the banner, and a click bringing the tab forward) is not reached by tests, which record notifications through `TerminalNotifications.current`.
- **Descriptors, reaping and forgotten sessions.** With every patch applied, `scripts/build.sh --checkout .work/CotEditor --test` passed 378 tests in 19 suites, and a tree of patches 1 and 2 with the same changes passed 135 tests in 6 suites. `scripts/check-signing.sh --checkout .work/CotEditor --pty` passed, the PTY and ssh tests included, under the hardened runtime.
- **Terminals through a root's launcher.** With the seam and its test, `scripts/verify-patches.sh --workspace .work/CotEditor --test` passed 118 tests after patches 1 and 2, and the full test plan with every patch 501.
- **A folder that is not on this Mac.** With the check for a local folder and its test, `scripts/verify-patches.sh --workspace .work/CotEditor --test` passed 115 tests in 6 suites after patches 1 and 2.
- **On patch 1's contract.** After terminals moved onto the contract for tabs that are not files, `scripts/verify-patches.sh --workspace .work/CotEditor --test` passed 110 tests in 6 suites after patches 1 and 2 in a fresh clone, the PTY tests included, and the PTY tests passed under the hardened runtime in the Remote app's signing check; the Shell app's own signing check was not repeated.
- **One app per prefix.** `scripts/verify-patches.sh --workspace .work/CotEditor --test` applied patches 1 and 2 to a fresh clone and ran their focused suites: 101 tests passed. Patch 2 is refused on plain upstream. `scripts/check-signing.sh --through shell --pty` built an ad-hoc signed Release `CotEditor-Shell-arm64.app`: identifier `local.coteditor-tabs.CotEditor-Shell`, `flags=0x10002(adhoc,runtime)`, no App Sandbox, no iCloud, only `arm64`, strict verification passes; the PTY tests passed in a test host re-signed with the hardened runtime and the ad-hoc entitlements. `scripts/sync-strings.sh` left every catalog unchanged, so no string was lost with the conditions.
- **Full test plan** (`scripts/build.sh --workspace --through shell --test-all`): 250 tests in 41 suites passed.
- **Earlier build model.** The results in the rest of this list were recorded when one patched tree built every app, through separate schemes and configurations (`CotEditor-Terminal`, `Debug-Remote` and so on) and compilation conditions. The commands they name no longer exist; the sources and tests they cover are unchanged apart from the removed conditions.
- **Application.** `scripts/workspace.sh` followed by `scripts/export-patches.sh` reproduced both patch files byte for byte. `scripts/verify-patches.sh --workspace .work/CotEditor --test` applied patch 1, and patches 1 and 2, to fresh clones of the pinned commit; the fully patched tree equals the workspace's. It confirmed that patch 2 alone is refused on upstream. Re-running `apply-patches.sh` on a patched tree is refused.
- **Focused tests, fresh clones, clean build.** After patches 1 and 2, in the terminal scheme, `TerminalSessionTests`, `TerminalColorsTests`, `TerminalPTYTests`, `DirectoryTabTests` (with its terminal extension), `DirectoryTabArchiveTests` and `DirectoryDocumentTests` passed: 100 tests. The same suites pass in the terminal scheme after patch 4. `CotEditor-Sparkle` builds after both patches.
- **Full test plan** (`scripts/build.sh --test-all`, terminal scheme): 236 tests. Only the two known locale-dependent `EditorCounterTests.formatCountValue()` expectations failed. This full parallel run is also the load under which timing-based waits in patch 1's overlap test would be flaky.
- **Unexplained once.** In one full-plan run, directly after `verify-patches.sh --test` had rebuilt the same app bundle from other checkouts, the test host exited cleanly (status 0) twice, in `directoryFileTabsRespectPreference` and then `renamingKeepsTabIdentity`. xcodebuild relaunched it and those tests were reported as failed. There was no crash report. Six further full-plan runs with an exit hook installed to record the caller never reproduced it. An external quit request around the rebuild is suspected but not confirmed.
- **Signing.** An ad-hoc signed `Release-Terminal` build has `flags=0x10002(adhoc,runtime)`, the entitlements listed above (no App Sandbox), both `x86_64` and `arm64`, and passes `codesign --verify --deep --strict`. It launches. Xcode adds `get-task-allow` to development signatures; a Developer ID export removes it. The PTY suite also passed in a test host re-signed with `--options runtime` and the terminal entitlements, so shells spawn under the hardened runtime and enhanced security.
- **Hands-on checks** in an ad-hoc signed Release build covered multiple terminals beside dirty files, full-screen programs, keyboard input, copy and paste, closing and quitting with cancellation, turning tabs off, restoration and folder repair, and project tools in the unsandboxed build. They are the origin of the status-view sizing rule, the + > New File item and tabs closing when their shell exits.
- **Not done:** a Developer ID signed and notarized build. The Shell app is for local testing. Ad-hoc success is not a claim of distributability: distributing it needs a Developer ID Application certificate, notarization credentials and a bundle identifier in the distributor's domain (`PRODUCT_BUNDLE_IDENTIFIER` in `CotEditor.xcconfig`).

**Mutation checks.** Each protection below was disabled on purpose, and its test failed:

| Protection disabled | Test that failed |
| --- | --- |
| SIGKILL escalation | `shutdownForcesSessionsThatIgnoreHangup` |
| Window-close terminal confirmation | `windowCloseAsksOnceAndStopsNothingUntilApproved` |
| Closing the tab when the shell exits | `exitingShellClosesItsTab`, `shellExitingDuringItsClosePromptClosesTheTabOnce` |
| Status-view sizing (the pane squeezed to 52 pt) | `terminalFillsTheContentPaneInEveryState` |
| The link decision | `clickedLinksOpenOnlyWebPages` |
| The Control-key override | `controlKeysReachTheShellBeforeMenuShortcuts` |
| Word and line editing keys | `editingKeysMoveAndDeleteAsOnTheMac` |
| The editing keys under the kitty keyboard protocol (leaving them to SwiftTerm there) | `editingKeysMoveAndDeleteAsOnTheMac` |
| The container's minimum-size guard | `hiddenTerminalKeepsItsSize` |
| Centering the grid (the terminal view filling the container) | `terminalFillsTheContentPaneInEveryState` |
| Focusing the terminal | `selectingATerminalMovesKeyboardFocusIntoIt` |
| The OSC 52 refusals | `outputCannotWriteTheClipboard`, `outputCannotReadTheClipboard` |
| The readability filter on theme colors | `unfittingOrUnreadableColorsKeepTheStandardOnes` |
| Honoring pinned theme appearance | `chosenThemeSwitchesToItsAppearanceVariant` |
| Observing the terminal theme setting | `terminalFollowsTheThemeSetting` |
| A local shell without a local folder starting in the home folder | `aWindowWithoutALocalFolderStartsLocalTerminalsInTheHomeFolder` |
| The engine's OSC 777 handler (registered for another code) | `notificationSequencesReachTheEngine` |
| Removing format characters from notification text | `decodesNotificationSequences` |
| The notification rate limit | `sessionForwardsNotificationsAtALimitedRate` |
| Suppressing notifications while the terminal is in front | `terminalNotificationsShowOnlyWhileTheTerminalIsNotInFront` |

These were disabled together in one run, since each guards a separate path; each listed test failed, and no other:

| Protection disabled | Test that failed |
| --- | --- |
| Marking the app's descriptors and the new PTY to close on exec | `shellsInheritNoDescriptorsOfTheApp` |
| Sleeping instead of blocking in the background wait (`usleep` in the grace period) | `sessionsStoppingTogetherLeaveThreadsFree` |
| Quitting finishing the background waits | `quittingFinishesSessionsOfTabsClosedJustBefore` |
| Collecting the exit status of a shell not reaped yet | `exitStatusIsCollectedFromAShellNotYetReaped` |
| Identifying the foreground group by its members (`getsid` of the group ID instead) | `shutdownForcesJobsWhoseGroupLeaderExited` |
| Coalescing bells | `aFloodOfBellsSoundsOnce` |
| Caching the folder bookmark | `archivingMakesTheFolderBookmarkOnce` |
| Stopping the process in the session's `deinit` | `aForgottenSessionStopsItsProcess` |
| Stopping the process in the engine's `deinit` | `aForgottenEngineStopsItsShell` |

The bounded wait after SIGKILL has no test: it matters only for a process in an uninterruptible wait, which a test cannot create reliably. The natural-exit reconciliation in `SwiftTermEngine` itself has none either, since the early exit notification cannot be provoked; `pseudoTerminalIsReleased` checks that a shell that exited on its own is reaped, and the helper it uses is tested directly.

## Known limitations

- **Working directory race.** SwiftTerm ignores a failed `chdir` in the child. The folder is validated just before the spawn, but a folder deleted in between would start the shell in the app's working directory.
- **Descriptors opened during a fork.** Descriptors are marked just before each shell starts, so one that another thread opens without `O_CLOEXEC` at that very moment can still reach the shell. Code that opens descriptors off the main thread should mark them itself.
- **Confirmation for any live shell.** The prompts appear whenever a shell is running, even if it is idle; there is no foreground-job detection.
- **Background jobs** are stopped by the shell's own hangup handling, not by the app. Detached jobs may outlive the tab.
- **Not tracked or restored:** the shell's current directory, and terminal output across relaunches.
- **No font setting.**
- **Settings export.** The terminal settings are registered apart from CotEditor's shared defaults list (Swift allows no conditional entries in it), so Settings export and import do not include them.
- **Strings** are English only.
