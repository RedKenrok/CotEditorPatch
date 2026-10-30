# CotEditorPatch

CotEditorPatch adds tabs to the folder windows of [CotEditor](https://coteditor.com), and optionally shells and webpages beside your files, and editing of files and folders on SSH servers.

When you open a folder in CotEditor, the window shows one file at a time. CotEditorPatch adds a tab strip to folder windows, so every file you open from the folder stays one click away. Further builds add shells that open as tabs in the same window, starting in the folder you are working on, then webpages, such as your local development server, and finally files and folders on SSH servers, edited like local ones.

CotEditorPatch is not a fork. The repository holds upstream CotEditor as a submodule, together with a series of four patches that are applied to it before building. It is an independent project, not affiliated with or endorsed by the CotEditor project. Inside the app, menus and dialogs still say CotEditor.

## Features

- **File tabs** (patch 1, in every app). Files you open from a folder open in tabs that keep their scroll position, selection and split editors. Tabs can be reordered, dragged out into a window of their own, closed with ⌘W and switched with ⌘1 to ⌘9, and they come back after a relaunch. They are off by default: turn them on in Settings > Window > **Use file tabs in directory windows**. [More about file tabs](docs/01-tabs.md#what-it-does).
- **Shell tabs** (patch 2). Your login shell, in a tab beside your files, starting in the folder. It has the Mac's word and line editing keys, colors from your CotEditor theme, and notifications from programs such as coding agents. [More about shell tabs](docs/02-shell.md#what-it-does).
- **Webpage tabs** (patch 3). HTTPS websites and local development servers, in a tab beside your files and shells. Nothing loads until you ask, and forms are never sent twice without asking. [More about webpage tabs](docs/03-webpage.md#what-it-does).
- **Remote files and folders** (patch 4). Files on SSH servers, opened through your own OpenSSH setup and saved only once the server has confirmed the result, with unsent changes kept on your Mac until then. Remote folders open in windows of their own, with the folder's tree in the sidebar and shells on the server. Nothing is installed on the server. [More about remote files](docs/04-remote.md#what-it-does).

## The four apps

Each app is built from the patches up to the one you choose, and `scripts/build.sh` names it after what it contains.

| App | Patches | What you get | Bundle identifier |
| --- | --- | --- | --- |
| `CotEditor-Tabs.app` | 1 (`--through tabs`) | CotEditor with file tabs, sandboxed as upstream | `com.coteditor.CotEditor`, as upstream |
| `CotEditor-Shell.app` | 1 and 2 (`--through shell`) | File tabs and shell tabs, **without the App Sandbox**, since a shell needs full access to your files and tools. The hardened runtime is kept. Without iCloud, General settings offer no copy of the settings in iCloud; settings are exported and imported as files. | `local.coteditor-tabs.CotEditor-Shell` |
| `CotEditor-Web.app` | 1 to 3 (`--through webpage`) | File tabs, shell tabs and webpage tabs, **without the App Sandbox**, as the Shell app. | `local.coteditor-tabs.CotEditor-Web` |
| `CotEditor-Remote.app` | all (`--through remote`, the default) | File tabs, shell tabs, webpage tabs and remote files, **without the App Sandbox**, since it runs `ssh` with your SSH configuration and keys. | `local.coteditor-tabs.CotEditor-Remote` |

The Shell, Web and Remote apps have their own identifiers, so they install beside a regular CotEditor and do not share its settings. Use Settings export and import to carry settings over; the shell settings, website data, saved connections and unsent remote changes are not included.

No app updates itself: to update, pull the repository and build again. No Developer ID signed or notarized build exists.

## Requirements

- macOS 26 or later (upstream CotEditor's requirement).
- Xcode 27.1 or later. Upstream builds with Xcode 27.2, and its project file uses the JSON project format (`project.xcproj`), which Xcode 27.1 reads.
- For every app except the Tabs app, Xcode's optional **Metal Toolchain** component: `xcodebuild -downloadComponent MetalToolchain`. SwiftTerm, the terminal emulator, compiles a Metal shader.
- For remote files: an SSH server with SFTP enabled that accepts your key. The system's `/usr/bin/ssh` is used.
- About 6 GB of free disk space for a build.

## Build it yourself

```sh
git clone --recurse-submodules github.com/RedKenrok/CotEditorPatch
cd CotEditorPatch
scripts/build.sh --through tabs --release --adhoc      # .build/Apps/Release/CotEditor-Tabs-arm64.app
scripts/build.sh --through shell --release --adhoc     # .build/Apps/Release/CotEditor-Shell-arm64.app
scripts/build.sh --through webpage --release --adhoc   # .build/Apps/Release/CotEditor-Web-arm64.app
scripts/build.sh --through remote --release --adhoc    # .build/Apps/Release/CotEditor-Remote-arm64.app
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
scripts/build.sh --through tabs --test       # the file tab test suites
scripts/build.sh --through shell --test      # the file tab and shell test suites
scripts/build.sh --through webpage --test    # the file tab, shell and webpage test suites
scripts/build.sh --through remote --test     # the file tab, shell, webpage and remote test suites
scripts/build.sh --test-all                  # CotEditor's whole test plan, with every patch
scripts/remote-fixture.sh start              # local SFTP test servers; later test runs also use them
scripts/remote-fixture.sh stop
```

- Run tests in a logged-in macOS session: some open real windows.
- The tests run inside the app, so they share the settings of the same app when you run it by hand. Tests that depend on a setting set it for themselves.
- The remote tests that need a real SSH server run only while `scripts/remote-fixture.sh` has its servers running, and are reported as skipped otherwise. The servers are the system's `sshd`, run as you on `127.0.0.1` with keys of their own; your SSH configuration, keys and agent are not used.
- The webpage tests use a small web server of their own on `127.0.0.1` and `::1`, and contact no other website.
- Full logs are written to `.build/logs/`.

## Documentation

- [`docs/`](docs/README.md): what each patch does and how it works, which patch is responsible for what, and what the tests cover.
- [`AGENTS.md`](AGENTS.md): how to develop and change the patches, for people and coding agents.

## License

CotEditorPatch is licensed the same way as CotEditor: the source code under the Apache License, Version 2.0, and CotEditor's image resources under CC BY-NC-ND 4.0. See [`LICENSE`](LICENSE). SwiftTerm, used by the Shell, Web and Remote apps, is under the MIT license. "CotEditor" is the name of the upstream project; if you distribute a build, use your own bundle identifier and respect that name.
