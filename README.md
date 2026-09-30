# CotEditorPatch

CotEditorPatch adds tabs to the folder windows of [CotEditor](https://coteditor.com), and optionally shells and webpages beside your files, and editing of files and folders on SSH servers.

When you open a folder in CotEditor, the window shows one file at a time. CotEditorPatch adds a tab strip to folder windows, so every file you open from the folder stays one click away. A separate build also lets you open shells as tabs in the same window, starting in the folder you are working on, the next one adds webpages, such as your local development server, and a fourth build adds files and folders on SSH servers, edited like local ones.

CotEditorPatch is not a fork. The repository holds upstream CotEditor as a submodule together with a series of patches that are applied to it before building. The patches are numbered 1 to 4. It is an independent project, not affiliated with or endorsed by the CotEditor project. Inside the app, menus and dialogs still say CotEditor.

## Features

**File tabs** (patch 1, in every build). Turn them on in Settings > Window > **Use file tabs in directory windows**. They are off by default.

- Files you open from the folder open in tabs. The tabs keep each file's scroll position, selection and split editors.
- The **+** button creates a new file next to the one you are looking at.
- Drag tabs to reorder them, or drag one out of the strip (or choose **Move to New Window** from its context menu) to give the file a window of its own, with its unsaved changes and undo history.
- ⌘W closes the selected tab, and File > **Close Window** (⇧⌘W) closes the window. Window > **Show Previous Tab** (⌘⇧[) and **Show Next Tab** (⌘⇧]), and ⌘1 to ⌘9, switch tabs.
- Closing a tab or window asks about unsaved changes, as CotEditor always does.
- Your tabs come back when you relaunch.

**Shell tabs** (patch 2, only in the `CotEditor-Shell` build).

- File > **New Shell Tab**, **New Shell** in the **+** menu, or **Open Shell Here** in the file browser opens your login shell in the folder.
- Shells and files share one row of tabs and the same tab commands. Shell tabs can be renamed.
- ⌥← and ⌥→ move the cursor by a word, and ⌘← and ⌘→ to the start and end of the line, as in Terminal.
- A **Shell** settings pane picks the colors: the editor's theme (the default) or any other CotEditor theme, with program colors matched to it.
- Closing a running shell, its window, or the app asks first. A shell that exits closes its tab.
- After a relaunch, shells come back as placeholders that start a new session when you ask. Output and running programs are not restored.

**Webpage tabs** (patch 3, only in the `CotEditor-Web` build, which also has shell tabs).

- **New Webpage** in the **+** menu, or File > **New Webpage Tab**, opens an empty tab with its address field ready. Nothing loads until you enter an address and press Return.
- HTTPS addresses work everywhere. HTTP works for local development servers: `localhost`, local and private IP addresses, names without a dot such as `devbox`, and names ending in `.local`. Type `http://` for those, as in `http://localhost:3000`; an address without a scheme gets HTTPS. The field takes addresses only; it does not search.
- Back, Forward, Reload (Stop while loading) and the address are in a bar above the page. The tab shows the page's title, and its tooltip the address. Switching tabs keeps the page and its history.
- A page that fails to load leaves the previous page as it was, and says which address failed. **Try Again** is offered only when the request can be sent again safely: a form that failed to send is never sent again by itself, and reloading or going back to a page made by a form asks first.
- Website alerts and questions appear as sheets that name the website that asked. Only the tab you are looking at can show them.
- **Clear Website Data…** in a webpage tab's context menu removes the cookies and data of every website, after asking.
- Closing a webpage tab, its window or the app never asks. After a relaunch, webpage tabs come back with their title and address, and load when you click **Load Webpage**.
- Websites cannot ask before their tab closes. A link that opens a new window opens in the same tab, so sign-ins that need a popup window to talk back to the page do not work. Development domains such as `.test` need HTTPS. There are no downloads, bookmarks or browser settings.

**Remote files** (patch 4, only in the `CotEditor-Remote` build, which also has shell and webpage tabs).

- File > **Open Remote File…**, or **Open Remote File…** in the **+** menu, opens a file on an SSH server: pick a saved connection or a host from your SSH configuration (`~/.ssh/config`, whose user and port are then used), or type a host, optionally with a user and port, and give the file's absolute path. The sheet shows what the host connects to. Recent paths are remembered per connection.
- The file opens in a tab next to your local files (or in a window of its own if file tabs are off). The tab looks like any file's; its tooltip and the inspector show `user@host:/path`.
- **Save** first checks that the file on the server is still the version you started from, then uploads a copy, checks it, and swaps it in. If the file cannot be replaced safely, for example because it belongs to another user, CotEditor asks once whether it may rewrite it in place.
- If someone else changed the file, nothing is overwritten: you can review the server's version, save yours under another path (**Save As Remote…**), or replace the version you reviewed. **Save a Local Copy…** and **Revert to Remote Version** are in the File menu.
- Unsent changes are kept on your Mac until the server has them: through failures, closing with **Keep Recovery Copy**, quitting and crashes. Remote tabs come back after a relaunch without connecting.
- CotEditor uses your Mac's OpenSSH (`/usr/bin/ssh`) with your SSH configuration, keys and agent, and the server's SFTP service. Nothing is installed on the server.
- If the server asks for a password, a one-time code or your key's passphrase, CotEditor asks you in a dialog. Answers are never stored, so each new connection asks again.
- A server whose key is not in your `known_hosts` yet shows its key's fingerprint; if it matches the one the server's administrator gave you, **Trust and Connect** adds it to `known_hosts`, as `ssh` would. A key that changed is refused, as `ssh` refuses it.
- Hosts reached through `ProxyJump` work, with each jump host checked as strictly as the server itself. A jump host that is itself reached through another must be named in the same `ProxyJump`. A `ProxyCommand` runs as your configuration says.
- A save or open that takes more than a moment shows its progress, with **Cancel** and **Allow 10 More Minutes**. Cancel works until the file on the server starts to change; after that, the save finishes. A lost connection while opening a file is tried again twice; a save is never repeated by itself.
- Files are limited to 16 MiB. SFTP cannot rule out a change by someone else in the moment between the last check and the save.

**Remote folders** (patch 4, in the `CotEditor-Remote` build).

- File > **Open Remote Folder…** (also in the **+** menu) opens a folder on an SSH server in a window of its own: pick a connection, then type the folder's path, leave it empty for the server's starting folder, or choose **Browse…** to find it, starting from where you were last time or from the server's starting folder. File > **Open Recent Remote Folder** reopens one.
- The sidebar shows the folder's tree. Folders are listed as you expand them, and a large one shows its first items while the rest arrive. Click a file to open it in a tab; it saves like any remote file. The arrow keys move through the tree without opening files, and Return opens the selected one.
- While the window shows, it lists its open folders again every 30 seconds, so that changes by others appear; SFTP cannot watch a folder. **Refresh** in the sidebar does it at once. Neither ever changes a file you are editing. The context menu has **Refresh Folder**, **Copy Remote Location**, **Open Folder in New Window** and **Show Hidden Files**.
- The filter below the tree works as in a local folder window: it finds names in the whole folder, listing the folders that were not listed yet, up to the window's limits. Links are not followed.
- If the connection drops, the tree stays, marked offline, and your open files stay editable; **Reconnect** lists it again. If the folder's path now leads somewhere else, for example because a link was changed, the window keeps showing the original folder and offers to open the new place in a new window.
- Folder windows come back after a relaunch, offline, with their tabs (or, with file tabs off, the file that was showing) and the part of the tree you had loaded, until you reconnect.
- Each folder window uses one more SSH connection to the server, for browsing, so with an agent that confirms every use, such as a hardware key, opening a folder can ask once more than opening a file.
- **New File** and **New Folder** (from the **+** button below the tree, the context menu, or New File in the tab strip's **+** menu), **Rename** and **Delete…** (in the context menu, or the Delete key) work as in a local folder window, and you move an item by dragging it onto a folder. Deleting is permanent, since a server has no Trash, and a folder goes with everything in it. A file you have open follows when it is renamed or moved, and closes when it is deleted; a file with unsaved changes, or being saved, must be saved or closed first.
- Drag files and folders from the Finder onto a folder to upload them, and drag a file to the Finder to download it. Names that are taken get a number; nothing on the server is replaced. Links are not uploaded, and files up to 16 MiB are.
- **New Shell** in a remote folder window opens a shell on the server, in the folder, through the same SSH connection settings. A session that fails keeps its tab, so you can read why and start it again. Remote shells are not restored after a relaunch.
- The window does not copy items on the server. Very large folders are listed up to 10,000 entries.

## The four apps

Each app is built from the patches up to the one you choose, and `scripts/build.sh` names it after what it contains.

| App | Patches | What you get | Bundle identifier |
| --- | --- | --- | --- |
| `CotEditor-Tabs.app` | 1 (`--through tabs`) | CotEditor with file tabs, sandboxed as upstream | `com.coteditor.CotEditor`, as upstream |
| `CotEditor-Shell.app` | 1 and 2 (`--through shell`) | File tabs and shell tabs, **without the App Sandbox**, since a shell needs full access to your files and tools. The hardened runtime is kept. | `local.coteditor-tabs.CotEditor-Shell` |
| `CotEditor-Web.app` | 1 to 3 (`--through webpage`) | File tabs, shell tabs and webpage tabs, **without the App Sandbox**, as the Shell app. The hardened runtime is kept. | `local.coteditor-tabs.CotEditor-Web` |
| `CotEditor-Remote.app` | all (`--through remote`, the default) | File tabs, shell tabs, webpage tabs and remote files, **without the App Sandbox**, since it runs `ssh` with your SSH configuration and keys. The hardened runtime is kept. | `local.coteditor-tabs.CotEditor-Remote` |

No app updates itself: to update, pull the repository and build again.

`CotEditor-Tabs.app`, `CotEditor-Shell.app`, `CotEditor-Web.app` and `CotEditor-Remote.app` have their own identifiers, so they install beside a regular CotEditor and do not share its settings. Use Settings export and import to carry settings over; the terminal's own settings, website data, saved connections and unsent remote changes are not included.

No Developer ID signed or notarized build exists.

## Requirements

- macOS 26 or later (upstream CotEditor's requirement).
- Xcode 27.0 or later.
- For every app except the Tabs app, Xcode's optional **Metal Toolchain** component: `xcodebuild -downloadComponent MetalToolchain`. SwiftTerm, the terminal emulator, compiles a Metal shader.
- For remote files: an SSH server with SFTP enabled that accepts your key, and the server's host key in your `known_hosts`. The system's `/usr/bin/ssh` is used.
- About 6 GB of free disk space for a build.

## Build it yourself

```sh
git clone --recurse-submodules github.com/RedKenrok/CotEditorPatch
cd CotEditorPatch
scripts/build.sh --through tabs --release --adhoc       # .build/Apps/Release/CotEditor-Tabs-arm64.app
scripts/build.sh --through shell --release --adhoc   # .build/Apps/Release/CotEditor-Shell-arm64.app
scripts/build.sh --through webpage --release --adhoc        # .build/Apps/Release/CotEditor-Web-arm64.app
scripts/build.sh --through remote --release --adhoc     # .build/Apps/Release/CotEditor-Remote-arm64.app
```

- `--through` names the last patch to include: `tabs`, `shell`, `webpage` or `remote`, or its number (`02`). Without it, every patch is included.
- The patches are applied in a checkout of its own, `.build/Checkout`; the `CotEditor` submodule is not changed. To get the patched source there instead, run `scripts/apply-patches.sh --through PATCH`.
- To build several apps, run the commands one after another, not at the same time: they share one build folder, so a later one only compiles what differs.
- Without `--release`, it makes a Debug build in `.build/Apps/Debug/`.
- Each build is for one kind of Mac: this Mac's by default, or the one you name with `--arch arm64` (Apple Silicon), `--arch x86_64` (Intel), or `--arch both` for one of each. The architecture is added to the app's name, as in the examples above, which assume an Apple Silicon Mac. Building for the other kind of Mac takes longer, since the build tools can only produce that app by building both and keeping one.
- `--adhoc` signs the app without a developer team, which is enough to run it on your own Mac. Without it the app is left unsigned.
- Each build replaces the previous copy of the same app, and prints its path.

If you applied patches to the submodule, `scripts/reset-submodule.sh` takes it back to plain upstream. It stashes any local changes in the submodule and prints how to recover them.

## Testing

```sh
scripts/build.sh --through tabs --test         # the file tab test suites
scripts/build.sh --through shell --test     # the file tab and shell test suites
scripts/build.sh --through webpage --test          # the file tab, shell and webpage test suites
scripts/build.sh --through remote --test       # the file tab, shell, webpage and remote test suites
scripts/build.sh --test-all                    # CotEditor's whole test plan, with every patch
scripts/remote-fixture.sh start                # local SFTP test servers; later test runs also use them
scripts/remote-fixture.sh stop
```

- Run tests in a logged-in macOS session: some open real windows.
- The tests run inside the app, so they use the same settings as the same app when you run it by hand.
- The remote tests that need a real SSH server run only while `scripts/remote-fixture.sh` has its servers running, and are reported as skipped otherwise. The servers are the system's `sshd`, run as you on `127.0.0.1` with keys of their own; your SSH configuration, keys and agent are not used.
- The webpage tests use a small web server of their own on `127.0.0.1` and `::1`, and contact no other website.
- Full logs are written to `.build/logs/`.

The last recorded results are in the Evidence section of each [design document](docs/README.md).

## Documentation

- [`docs/`](docs/README.md): how each patch works, which patch is responsible for what, and the test evidence.
- [`AGENTS.md`](AGENTS.md): how to develop and change the patches, for people and coding agents.

## License

CotEditorPatch is licensed the same way as CotEditor: the source code under the Apache License, Version 2.0, and CotEditor's image resources under CC BY-NC-ND 4.0. See [`LICENSE`](LICENSE). SwiftTerm, used by the shell tabs, web and remote builds, is under the MIT license. "CotEditor" is the name of the upstream project; if you distribute a build, use your own bundle identifier and respect that name.
