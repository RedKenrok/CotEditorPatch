# Patch 1: directory file tabs

`patches/01-tabs.patch` adds opt-in **file tabs inside a folder window**, independent of macOS native window tabs, and is the foundation every later kind of tab builds on. It applies to plain upstream and is usable on its own. It has no SwiftTerm dependency, no terminal code, and no build, entitlement or signing change.

See [the overview](README.md) for how this patch divides the work with the later patches.

## Preference

`usesDirectoryFileTabs` defaults to false and is exposed in Window settings. An observer applies changes to every open folder window. The tab strip is shown whenever the preference is on, even with no file open, so opening the first file does not grow it and push the editor down.

## Tab model

- `DirectoryDocument` owns a registry of `DataDocument` children. `DirectoryTabState` separately models the visible ordered entries and the selected UUID.
- Inserting an entry never selects it. Only the directory selects, together with switching the content host, so the selected tab always names the file on screen.
- File entries keep their document identity. The registry keeps edited inactive files while tabs are off. Turning tabs on again reconciles still-owned files into entries without reopening them, and keeps their UUIDs.
- `activeFileDocument` derives the active file from the selected entry when tabs are on, and from the current file otherwise. File-only actions, scripting, folder find and browser selection all use this accessor.
- **Tabs that are not files.** An entry is either a file or an item of the contract below (`Entry.Content.item`). `Entry.document` is optional, and `reconcile` keeps entries that are not in the document registry at their place among the files. Selecting such a tab yields no active file. This patch itself only creates file tabs; its tests prove the contract with a fake kind.
- **Ready for documents without a file.** `adoptMember(_:tabID:select:)` makes an already open document a member, with a tab when tabs are on, registering it with the document controller if needed; opening a file uses the same routine. It refuses a document that another directory owns, since two registries would both close and archive it. Nothing in the tab model, closing or moving to a window depends on a file URL.
- `arrange(by:)` puts entries into an archived order, keeping entries it does not know after them. Restoration applies it again as each tab arrives, since tabs of different kinds reopen at different times.
- Each member carries a weak `directoryDocument` back-reference. It routes an inactive member's sheets (`windowForSheet`) to the folder window instead of whichever window is main. It also lets a member closed outside the directory be removed from the registry, the tabs and the editor cache exactly once: AppKit's Close All and quit review close children directly, newest first.

## Tabs that are not files

Every later kind of tab that is not a file, such as a terminal or a webpage, goes through one contract, so that none of them needs a branch of its own in the tab state, the content host, close handling or the archive. It is not a plugin system: the patch that adds a kind registers it in `DirectoryTabKind.registered`, which is empty here.

- **`DirectoryTabItem`** (a main-actor protocol) is one such tab: its ID, its archive kind, its presentation (title, icon, tooltip, and the content's accessibility label), a controller for the content host, an optional asynchronous approval to close this one tab, a notice before the directory shows a review of its own (`directoryWillShowReview()`, so that the tab can take away a sheet it shows), a teardown, its archive fields, and its context-menu items. The title and tooltip are read inside the tab strip's observation, so an observable item refreshes the strip when they change.
- **`DirectoryTabKind`** describes a kind as a whole: its archive kind, one approval for all its tabs when a window closes, how to recreate its archived tabs as items, or as member documents for a kind whose tabs are documents without a file in the folder (`restoreDocuments`), and optional **+** menu items (`addMenuItems`), each of which can be disabled (`DirectoryTabBar.MenuItem.isEnabled`). `DirectoryDocument.tabKinds` holds the kinds a directory has; tests give it kinds of their own.
- **`DirectoryDocument+TabItems`** is the shared part: `openTabItem(_:)` (tabs on only), `selectTabItem(_:)`, which detaches the current file from the window (`detachCurrentDocument()`) and shows the item, `closeTabItem(_:)`, which refuses repeated requests and requests during a window-close review, asks the item, and checks again that the tab still exists, `removeTabItem(_:)`, which tears the item down, releases its controller and shows the tab that takes over the selection, and `closeAllTabItems()`. Whether the removed tab was selected is read from the tab state itself, not from `activeTabItem`, which is `nil` once tabs are off. A closing window shows nothing more, so there the selection is not handed on at all: it would build an editor, or even a window of the member's own, only to close it.
- **Content host.** `WindowContentViewController` caches one controller per item ID (and item identity) while the tab is open, and releases it when the tab closes. `ContentViewController.showTabContent(_:)` hosts it in place of any document; the outgoing editor stays in the editor cache, and focus moves into the tab (`focusTabContent()`) when the editor had it. The inspector and status bar are empty while such a tab is selected, the window subtitle is its title, and the file browser keeps the last file highlighted as context.
- **Closing.** `canCloseMembers` notifies every item of the review, then asks each registered kind once for its tabs, then the dirty files. Nothing is torn down until `close()`, after every approval. Turning tabs off closes every item, since none can be shown without tabs. If an item was selected, the file next to it shows and is the file kept open; the unedited hidden files close as usual, and with no file shown none is disposed of.
- **Archive.** Each item is archived under its own kind with the fields it gives; a member document chooses its entry through `tabArchiveRepresentation`. `restoreForeignTabs` asks each kind to recreate its entries, inserts the items and adopts the documents under their tab IDs, applies the archived order and selects the archived selection if it is one of them.

## Folders that are not on this Mac

A directory window can also show a folder that is not on this Mac, such as a folder on a server. Its `DirectoryDocument` has no file URL, since nothing local stands for the folder, and a **root** instead (`DirectoryRoot`, a main-actor protocol, given to `init(root:)`). It is not a file-system abstraction: the root supplies only what a missing local folder leaves open, and patch 1 has no branch for any particular root.

- **Name and sidebar.** The root gives the title (`displayName`) and the subtitle shown while no tab gives one, and makes the sidebar, which takes the place of the file browser and folder find, and optionally the sidebar's top accessory, which the window places right below its title bar as it does the local sidebar's pane switcher.
- **Restoration.** AppKit restores only documents with a file, so the window is not restorable, and the root keeps what restores it. `directoryDidChangeState(_:)` is called wherever the restorable state is invalidated, until the window starts closing, so that closing tab by tab never archives an empty window. `tabArchive` is the archive the restorable state stores, and `restoreTabs(fromArchive:)` recreates the tabs of the registered kinds from it; file entries are skipped, since they name local files by bookmark. With file tabs off, it reopens the kinds' member documents without tabs and shows the one that was selected, since no restoration of AppKit's brings back a document of a window without a file.
- **Closing.** `directoryDidClose(_:)` is called once, after every approval, at the end of the outermost `close()`; AppKit closes the document again from within it while closing the window.
- **Commands.** Without a local folder, the **+** menu has **New File** only if the root can create files (`canCreateFiles`), and then the root creates it (`createFileInNewTab(in:)`). `closeMemberWithoutReview(_:)` closes a member whose file is gone, such as one the root deleted, as the file browser's Move to Trash does. Members, tabs of every kind, the file tabs preference, Move to New Window and the close review work as in any directory window.

## The folder's own edited state

The folder document itself is never edited (`updateChangeCount(_:)` does nothing): its members hold every change, and the window's edited marker follows them. Views that are not file editors, such as a webpage's fields, a filter field or a terminal, record their undo steps in the window's document, which is the folder. Counted as changes, they made AppKit autosave the folder; since the folder had changed on disk, AppKit asked about saving anyway, and saving a folder, which cannot be written, crashed the app.

## Tab strip

- `DirectoryTabPresentation` is display-only metadata. `DirectoryTabBar` uses UUIDs for identity, scrolling and the select and close callbacks.
- A file tab's title, tooltip, icon and an optional badge symbol after the title come from overridable `DataDocument` properties (`tabTitle`, `tabToolTip`, `tabIcon`, `tabBadgeSymbolName`), and the folder window's subtitle from `subtitleName`. Their defaults are what the file URL gives, exactly as before; a document without a local file can say where it is instead. `standaloneWindowSubtitle` gives a document's own window a subtitle; it is `nil` by default, which leaves upstream's behavior.
- After the tabs, a **+** menu is built from **New File** and the **+** menu items of the registered kinds. **New File**: it creates an empty file next to the file in the selected tab (or in the folder itself), opens it in a new tab, and lets the file browser start editing its name, as the browser's own New File does.
- Per-tab context-menu items are a second list. File tabs offer **Move to New Window**; other tabs offer their item's own items.
- The strip refreshes on edited-state and file-URL changes, so renamed files update their titles. Every document in the app posts those notifications, about every change, so the strip is rebuilt only when a file tab's title, tooltip, edited marker or badge differs from what it last showed. A file tab's icon is looked up once per file URL.
- `WindowContentViewController` hosts the strip and switches between file and empty content. When the editor had keyboard focus, it hands focus to the incoming editor's focused split; focus in the sidebar or inspector is left alone.

### Dragging to reorder

- A tab can be dragged along the strip. The other tabs animate aside and the order changes live. The tab takes the place of the first other tab whose middle it passes (`DirectoryTabBar.dropIndex`), which gives natural hysteresis, so tabs don't flicker at the boundary.
- Each tab's place is measured outside the offset that moves the dragged tab. Measured inside, SwiftUI reports the frame with that offset included, so every drag step would measure the tab where the previous step drew it, and the tab would jitter while the pointer moves.
- Auto-scrolling to the selected tab is paused during a drag, since it would move the strip under the pointer.
- During a drag, the strip keeps its own display order and animates each reorder once, in a single transaction, while the model follows. An implicit animation on the model's order would animate every later rebuild of the strip again, and the icons would trail behind the titles. Tabs opening or closing are not animated.
- Tabs have no background of their own, so the dragged tab gets an opaque one, in the window background color with a slight shadow, while it slides over its neighbors.
- `DirectoryDocument.moveTab(id:to:)` changes the order without changing the selection. It also puts the document registry in tab order, so turning tabs off and on keeps the user's order; the archive keeps it across relaunches.

### Moving a tab to its own window

- Pulling a tab more than `pullOutDistance` above or below the strip turns it translucent. Letting go there moves it to a window of its own, with the window's title bar under the pointer. **Move to New Window** in the context menu does the same without dragging.
- The document object itself moves: the file leaves the folder for a standalone document window, and unsaved changes and undo history go with it. The editor's selection is read from the tab's editor (on screen or cached) and applied in the new window. The file browser's Open in New Window shares this path.
- A preview document cannot have a window of its own, so it is reopened as a regular document at the same place.
- The new window is not a second folder window: CotEditor keeps one directory document per folder. Moving a tab into another folder window is not supported.

### Accessibility

Tabs offer Move Left, Move Right and Move to New Window as accessibility actions, so reordering doesn't depend on dragging. The strip has its own accessibility strings (`File Tabs`, `New Tab`, `Close <file>`, `Edited`).

## Content host and viewport

- `ContentViewController` detaches the hosted controller in one routine, so that another kind of content can take the host without bypassing the editor cache.
- It caches detached editor controllers by document identity, keeping split editors and all selected ranges. Closing a tab releases its cached controller.
- Each split's clip position is stored relative to the clip view's content insets, since the topmost legal origin is negative. It is restored after reattaching, clamped with `NSClipView.constrainBoundsRect(_:)`.
- A new editor is measured the same way before it is attached. Otherwise AppKit applies the toolbar and tab-bar insets (80 pt in testing) without moving the clip origin, and the first lines of the file are hidden under the bar.
- Text is laid out lazily, so before a position is clamped, the text is laid out as far as the view will show at that position. Otherwise, under load, the document could still be too short when the tab comes back, and the view would come back higher than it was left.
- One deferred re-check after the next layout reapplies the position only if the host still shows that editor (a switch generation guards it) and nothing else scrolled it meanwhile.

## Commands

- **File > Close** (⌘W) closes the selected tab, whatever kind it is, through `closeTab(id:)` when the preference is on. The check ignores the key equivalent, since users can rebind it. The Close All alternate, the window button, programmatic closes and the tabs-off path stay window closes.
- **File > Close Window** (⇧⌘W, rebindable) is added after Close and its Close All alternate. Upstream has no such item, and a folder window with files open would otherwise have no keyboard command to close it.
- **Window > Show Previous Tab** (⌘⇧[) and **Show Next Tab** (⌘⇧]), as in Safari and Xcode, and ⌘1 to ⌘9, walk the tabs of a folder window. Folder windows cannot join native tab groups, and AppKit adds its own Show Next/Previous Tab items only for windows in such a group, so folder windows would otherwise have no visible command. The items use AppKit's actions, so they also switch native tabs in regular document windows. They are added before key bindings are read, so they can be rebound. The running Window menu shows no second set of items from AppKit.

## Closing

- Closing a file tab asks the document for unsaved-change permission before removing it. Every close path asks through one function, `approveMemberClose`, which defaults to the document's own `canClose()`; tests replace it to control exactly when a member answers.
- Repeated close requests for the same child are blocked, and membership is rechecked after the asynchronous prompt.
- The selected tab's successor is its next neighbor, then its previous neighbor. Closing the last tab leaves the folder window open.
- Members that AppKit closes itself (Close All, the quit review) close one after another in one turn. The successor is then shown on a later turn of the main queue, once for all of them, and not at all if the window closed or something else was selected meanwhile; `activeFileDocument` is `nil` until then, so the host builds no editor for a file that is about to close too.
- Window close (`shouldCloseWindowController`) and Close All (`canClose(withDelegate:)`) collect member approvals through one routine (`canCloseMembers`). It removes nothing, refuses overlapping requests and pending tab closes, and refuses the close if membership changed during a sheet. Restoration waits while such a review runs, since a file it reopened meanwhile would make the review refuse what the user approved.

## Restoration

- A versioned, secure-coding-compatible archive (`DirectoryTabArchive`, version 1) holds one entry per tab, with its UUID and kind, in tab order, and the selected UUID. A document chooses its entry through `tabArchiveRepresentation`; a document with a file is archived as a `file` entry with a security-scoped bookmark.
- **Entries of other kinds** keep their place: decoding keeps the order of every valid, unique ID (`order`) and hands entries of kinds it does not reopen itself to the registered kinds as `foreignEntries`, through `restoreForeignTabs`, which runs before the files reopen and may take the saved selection. An entry of another kind needs a valid ID of its own; an entry without a kind is skipped. Builds without those kinds skip them, so every build reads the same archive.
- Every owned member is archived, including edited files hidden while tabs are off. With tabs off only the visible file reopens; turning tabs on before the next launch brings the others back as tabs.
- Unsaved changes are never held only in the archive: autosave in place writes them, or the quit review prompts.
- Decoding falls back to the legacy `openDocuments` list and then to `currentDocument`. Unknown kinds and versions, unresolvable bookmarks, duplicate files and duplicate IDs are skipped or repaired.
- Members reopen without activation, yielding between members. The saved selection is shown as soon as it opens, unless the user has selected something meanwhile. Closing the folder window cancels the task. If tabs are turned off meanwhile, only the file that is to show still reopens; the others would only be hidden.
- Bookmarks are resolved but no security scope is started, since members are read under the directory's own access, so there is nothing to balance.
- Restorable state is invalidated on selection, membership and member URL changes, and on tab moves; a URL change of a document that is not a member leaves it alone. Preview documents already owned by the directory are reused rather than duplicated.
- The state is encoded on the main thread after each of those changes, and a security-scoped bookmark is a round trip to another process, so each document keeps its tab's bookmark and makes a new one only when its file URL or modification date changes (a save may replace the file). The bookmark of the file on screen is the same one.

## File browser

Selecting a file programmatically also selects its row in the file browser, and the browser opens the selected file on a later turn of the main queue. That open is skipped if the directory's selection changed in between, as it does when a keyboard command selects the next tab at once; otherwise the file whose row was highlighted would take over from the tab the user selected.

## Strings

- The tab strings (`File Tabs`, `New Tab`, `Close <file>`, `Edited`, the Move actions) and the menu items (`Close Window`, `Show Previous Tab`, `Show Next Tab`) are in the upstream `Document.xcstrings` table.
- The preference label (`Use file tabs in directory windows`) is in `WindowSettings.xcstrings`.
- The translations of those strings have been reviewed and are marked `translated`.
- The New File item reuses the file browser's existing `New File` string.

## Tests

- `DirectoryTabTests` is one serialized suite, because every test changes the global preference. It covers tab state, preference toggling, ownership and all close paths, restoration through `NSKeyedArchiver`, empty-host command validation, keyboard commands, File > Close Window and accessibility labels.
  - `overlappingCloseRequestsAreRefused` holds the first request's member approval open through `approveMemberClose` until the test answers it, so the overlap is exact under any load. The real autosave path is covered by `directoryConfirmsEditedMembersBeforeClosing`.
- `DirectoryTabTests+Viewport` drives a real window: the exact top edge (with and without line numbers and the navigation bar), independent x and y offsets away from the caret, split editors with multiple selections and focus, vertical layout, rapid A, B, A, B switching, reselection, content shrunk while hidden, close and reopen, rename, sidebar focus and the empty host.
- `DirectoryTabArchiveTests` covers archive round trips, migration and repair, entries of other kinds in their order with repeated or missing IDs, and tabs whose fields try to override their ID or kind.
- `adoptedDocumentsWithoutAFileJoinTheTabs` adopts a document without a file that describes and archives itself: it becomes the active tab once, its presentation comes from its properties, it is archived under its own kind in tab order, and it closes like any member. `tabStateArrangesEntriesByArchivedOrder` covers `arrange(by:)`.
- The helper that encodes a directory's restorable state waits for the background queue before finishing the archive, as AppKit's own restoration does. AppKit adds work to that queue for documents without a file, and an archive finished earlier makes that work throw.
- Reordering and moving to a new window are covered by tests of the model (moving entries), of the drag maths (drop index and pull-out), of order persistence (across relaunch, and turning tabs off and on, in a real window since the preference observer needs one), and of moving a tab to a new window (the same document object, its edits, undo history, selection and window position, and the folder window staying open when its last tab leaves).
- `DirectoryTabTests+Items` proves the contract for tabs that are not files with `FakeTabItem` and `FakeTabKind`: shared order and selection with files, presentation, no active file, no Move to New Window, tabs off, the cached controller (reused on switching, released on close, a new one for a new item with the same ID), file commands disabled, the title following observable state, the file browser not bringing a hidden file back, a tab close waiting for its approval and refusing a second request and a window close meanwhile, the window close asking the kind once and tearing down only after every approval, turning tabs off, the **+** and context menus, and archiving and restoring by kind, with a build without the kind skipping its entries, and a kind restoring member documents in order with the selection (`kindsRestoreMemberDocumentsInOrder`).
- Further tests cover the tab-system edge cases: turning tabs off while an item is selected (`turningTabsOffWhileAnItemShowsKeepsAFileShowing`), closing the window then (`closingTheWindowWhileAnItemShowsBuildsNoEditor`), a close review while restoration still reopens files (`aCloseReviewDuringRestorationIsNotRefused`), turning tabs off during restoration (`turningTabsOffDuringRestorationReopensOnlyTheShownFile`), members closed in a row by AppKit (`membersClosingInARowBuildNoEditorsForEachOther`), a document of another directory (`adoptionRefusesADocumentOfAnotherDirectory`), the bookmark after a rename (`archivedBookmarksFollowRenamedFiles`), and the strip left alone by other documents (`otherDocumentsLeaveTheTabStripAlone`, through the strip's build count).
- `typingOutsideAFileNeverEditsTheFolder` checks that a change recorded in the window's document, as a webpage's field records one, leaves the folder unedited and without changes to autosave.
- `DirectoryTabTests+Root` proves the root contract with `FakeDirectoryRoot`: no file URL, the root's title, subtitle and sidebar, a window AppKit does not restore, no New File, the root's sidebar accessory, the tabs archived and restored through the root, state changes reported while open but not while closing, the close reported once, and the file tabs preference.
- The drag gesture itself is checked by hand. Automated tests cannot see where SwiftUI draws a dragged view: its accessibility tree is only built for an active assistive client, and bitmap captures do not draw its layers.

## Evidence

Environment: Xcode 27.0 (27A266a), macOS 27.0 (Darwin 27.0.0), locale `en_NL`.

- **Tests and Release build.** With the SFTP fixture running, `scripts/verify-patches.sh --workspace .work/CotEditor --test` passed 64 tests in 3 suites after patch 1, and the full test plan with every patch (`scripts/build.sh --checkout .work/CotEditor --test-all`) passed 505 tests in 54 suites. `scripts/build.sh --arch arm64 --release --adhoc` built `CotEditor-Remote-arm64.app`.
- **Tab-system hardening.** With the tests for turning tabs off with an item selected, closing then, close reviews and tabs off during restoration, members closed in a row, adoption, bookmarks and strip refreshes, `scripts/build.sh --checkout .work/CotEditor --test` passed 369 tests in 19 suites with every patch applied, and the same change on the patch 1 tree alone passed 72 tests in 3 suites.
- **New File through a root.** With the hook and its test, `scripts/verify-patches.sh --workspace .work/CotEditor --test` passed 64 tests in 3 suites after patch 1.
- **Folders that are not on this Mac.** With the root contract and its tests, `scripts/verify-patches.sh --workspace .work/CotEditor --test` applied every prefix to fresh clones; after patch 1, 62 tests in 3 suites passed.
- **Tabs that are not files.** With the contract and its tests, `scripts/verify-patches.sh --workspace .work/CotEditor --test` applied every prefix to fresh clones; after patch 1, 58 tests in 3 suites passed.
- **One app per prefix.** `scripts/verify-patches.sh --workspace .work/CotEditor --test` applied patch 1 to a fresh clone and ran its focused suites: 49 tests passed. `scripts/check-signing.sh --through tabs` built an ad-hoc signed Release `CotEditor-Tabs-arm64.app`: upstream's identifier `com.coteditor.CotEditor`, `flags=0x10002(adhoc,runtime)`, App Sandbox on, only `arm64`, strict verification passes.
- **Earlier build model.** The results in the rest of this list were recorded when one patched tree built every app, through separate schemes and configurations (`CotEditor-Terminal`, `Debug-Remote` and so on) and compilation conditions. The commands they name no longer exist; the sources and tests they cover are unchanged apart from the removed conditions.
- `scripts/verify-patches.sh --workspace .work/CotEditor --test` applied patch 1 to a fresh clone of the pinned commit. The focused suites (`DirectoryTabTests`, `DirectoryTabArchiveTests`, `DirectoryDocumentTests`: 49 tests) passed in the standard `CotEditor` scheme. The same suites also pass in the terminal and remote schemes after patches 2 and 3.
- **Full test plan** (`scripts/build.sh --workspace --through tabs --test-all`): 198 tests in 38 suites passed. Upstream's `EditorCounterTests.formatCountValue()` compared counts with US-style text, and failed in locales that group thousands otherwise, such as `en_NL`; this patch changes that test to compare with the locale's own formatting of the number. Earlier runs, before that change, reported its two expectations as the only failures. Upstream's `URLDetectorTests.updateAfterEditing()` gave up after 2 seconds, although the detector waits up to three quarters of a second after an edit at utility priority, and failed in some full runs with every patch; this patch gives it 10 seconds, which it uses only when the machine is busy.
- The tests ran in an unsigned Debug build.
- `scripts/build.sh --variant standard --release --adhoc` built `CotEditor-Tabs.app` from the workspace: universal (`x86_64` and `arm64`), sandboxed, without iCloud, `flags=0x10002(adhoc,runtime)`, and it passes `codesign --verify --deep --strict`.

**Mutation checks.** To confirm the tests detect the bugs they guard against, each of the following was disabled in turn, and the named test then failed:

| Disabled | Test that failed |
| --- | --- |
| Restoring a root's member documents with file tabs off | `withFileTabsOffAFolderWindowComesBackShowingItsFile` (patch 4's test of the hook) |
| A root creating the file for New File | `aRootThatCreatesFilesOffersNewFileAndCreatesThem`, `newFileInTheTabStripCreatesARemoteFileInATab` |
| The member-close hook | the external-close test |
| The new-editor measurement | the close and reopen test |
| Registry ordering after a move | `movedTabsKeepTheirOrder` |
| Selection hand-over | `tabMovesToANewWindowWithItsDocument` |
| Window placement | `tabMovesToANewWindowWithItsDocument` |
| The drop-index comparison | `dragPositionsDecideTheDropIndexAndPullOut` |
| The controller cache for tabs that are not files | `hostCachesTheControllerOfEachItem`, `pagesFollowNavigationAndSurviveTabSwitches`, `dialogsOfHiddenTabsOrDuringAReviewAreAnsweredSafely` |
| Teardown only after every approval (items torn down when the review starts) | `windowCloseTearsItemsDownOnlyAfterEveryApproval`, `windowCloseAsksOnceAndStopsNothingUntilApproved`, `closingWebPagesNeverAsksAndACancelledCloseKeepsThem` |
| Archiving each item under its own kind (archived as `terminal`) | `tabItemsAreArchivedAndRestoredByTheirKind`, `restoredWebPagesLoadNothingUntilAsked` |
| The file browser's selection-generation check | `hostCachesTheControllerOfEachItem`, `pagesFollowNavigationAndSurviveTabSwitches` |
| The folder never edited (changes counted as for any document) | `typingOutsideAFileNeverEditsTheFolder` |
| Telling the root of the close once (on every close) | `closingTellsTheRootOnceAndArchivesNothingOnTheWay` |
| No state changes reported while closing | `closingTellsTheRootOnceAndArchivesNothingOnTheWay` |
| Restoring member documents by kind | `kindsRestoreMemberDocumentsInOrder`, `remoteTabsComeBackOfflineInTheirPlace`, `aTabWhoseRecoveryIsGoneBecomesAPlaceholder`, `webPagesShareTheTabsWithRemoteFiles` |
| Reading the removed tab's selection from the tab state (read through `activeTabItem`) | `turningTabsOffWhileAnItemShowsKeepsAFileShowing` |
| Handing on no selection while the window closes | `closingTheWindowWhileAnItemShowsBuildsNoEditor` |
| Restoration waiting for a close review | `aCloseReviewDuringRestorationIsNotRefused` |
| Reopening only the shown file once tabs are off | `turningTabsOffDuringRestorationReopensOnlyTheShownFile` |
| Deferring the successor of members AppKit closes | `membersClosingInARowBuildNoEditorsForEachOther` |
| Refusing a document of another directory | `adoptionRefusesADocumentOfAnotherDirectory` |
| Keying the kept bookmark by file URL | `archivedBookmarksFollowRenamedFiles` |
| Rebuilding the strip only when a file tab changed (rebuilt on every notification) | `otherDocumentsLeaveTheTabStripAlone` |

The last thirteen were checked with later patches applied, so tests of those patches failed too. The last eight were disabled together in one run, since each guards a separate path, and each named test failed, and only those.

The lazy-layout fix was found through `independentOffsetsAwayFromCaretSurviveSwitching`, which failed in two of four runs of the focused suites (the tab came back 147 points higher) and passed in five runs in a row after it. Since the failure depends on load, it is not in the table above.
