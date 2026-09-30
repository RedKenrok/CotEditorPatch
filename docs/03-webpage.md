# Patch 3: web pages

`patches/03-webpage.patch` adds **webpage tabs beside file and shell tabs in folder windows**, and makes the app the `CotEditor-Web` app. It is the delta from the exact exported state of [patch 2](02-shell.md) and does not apply to plain upstream or to patch 1 alone. The Tabs and Terminal apps are built from shorter prefixes, so they contain no WebKit use and no webpage command.

A webpage tab is a kind of tab through patch 1's [contract for tabs that are not files](01-tabs.md#tabs-that-are-not-files). This patch adds no branch to patch 1's tab state, content host, close handling or archive.

See [the overview](README.md) for how this patch divides the work with the others.

## Changes to shared code

- Webpage sources live in `CotEditor/Sources/WebPages/`, with names starting with `WebPage`.
- Shared files are edited directly, and only to register the feature: `.webPage` in `DirectoryTabKind.registered`, the File menu item in `AppDelegate`, the command validation in `DirectoryDocument+Actions`, the bundle identifier in `Configurations/CotEditor.xcconfig` and `NSAllowsLocalNetworking` in `CotEditor/Info.plist`. No existing line changes except the registered kinds and the bundle identifier.

## Build configuration

- **Identity.** `Configurations/CotEditor.xcconfig` sets `local.coteditor-tabs.CotEditor-Web`, and `build.sh` copies the app as `CotEditor-Web-<architecture>.app`. There is no scheme, configuration or compilation condition of its own.
- **Entitlements.** Patch 2's: no App Sandbox, the hardened runtime kept. Webpages themselves would work in the sandbox; the terminals need it off.
- **Transport.** `Info.plist` gets `NSAppTransportSecurity` with `NSAllowsLocalNetworking` only. App Transport Security already allows IP literals and `localhost`; the key admits unqualified names and `.local` names. `NSAllowsArbitraryLoads` and `NSAllowsArbitraryLoadsInWebContent` are never set.
- **Framework.** The system's WebKit, with no third-party dependency.

## Session and controller

- `WebPageSession` (main actor, observable) is the tab's item: a stable ID, the lifecycle (`empty`, `restored`, `active`, `contentProcessEnded`, `closed`), the current address, the page title, loading and history state, and the last failure or notice. It is not an `NSDocument` and has no file URL or edited marker.
- `WebPageViewController` owns one `WKWebView` for the tab's life, with an AppKit navigation bar (Back, Forward, Reload or Stop, the address field) and a message bar under it. Patch 1's host caches the controller per tab, so switching tabs only moves it in and out of the window, and the page and its history stay as they are. Closing tears the controller down: it takes away any question on screen, drops its UI delegate and observations, stops loading, and loads an empty page, which ends the page's scripts, timers and media even while something still holds the web view. The navigation delegate stays and refuses every navigation but that empty page, so a page that is still running cannot go anywhere else.
- History and loading state are WebKit's own, read through key-value observation; there is no parallel history. A tab that is not on screen records WebKit's changes but updates its views only when it appears.
- A placeholder view (SwiftUI, `sizingOptions = []`, so its content never constrains the split view) covers the web view for a new tab, a restored tab, a web content process that ended, and a first navigation that failed. It is made once and reads the session itself.
- **The address is the committed page's.** `WKWebView.url` is already the destination while a navigation is provisional, so a page that starts a load to a server that never answers would otherwise show that server's address in the address field, the title's host fallback, the tooltip and the archive, while its own content stays on screen. The session takes the address from the back-forward list's current item instead, which changes only when a navigation commits or the page changes its own address (`history.pushState`, a fragment). Until a page commits, the tab has no address.
- **Titles.** The tab title is the page title, made one line and cut at 200 characters, then the host, then **Webpage**. The tooltip is the address. A globe identifies the tab. The content's accessibility label is `Webpage: <title>`.
- **Address field.** Return loads the text. Escape gives up the edit and shows the current address. The field follows navigation and redirects, but never while the user is editing it. A new tab starts with keyboard focus in the field.

### Navigation state

- WebKit reports each navigation with a `WKNavigation` object. The session keeps a token for the navigation that started last, and ignores events of any other, so a late completion, failure or cancellation of an older load never changes a newer one's state.
- Cancellations (`NSURLErrorCancelled`, and WebKit's error 102 for a load interrupted by a policy decision) are not failures: Stop, a superseded navigation and a refused destination show no failure.
- **Keeping the page.** A navigation that fails before it commits leaves the page that is showing, its form values and its history untouched. The failure appears in the message bar and names the address that failed. No error document is loaded into the web view. With no page yet, the placeholder explains the failure, the failure does not claim a previous page, and the tab archives no address. A failure after the page changed explains itself without claiming the previous page can come back.
- **Retry** is offered only when the failed request can be repeated safely. `decidePolicyFor` records the main frame's decision (address, and whether it is a GET without a body and not a form submission). The next navigation to start takes that decision only if it asked for the same address; otherwise the navigation counts as not repeatable. A redirect is repeatable only if every request in it was. Retry starts a new GET for the failed address. Request bodies are never kept, and a failed form submission is never rebuilt from its address: the message says the request was not sent again.
- **Resubmission.** Reload or history navigation to a page made by a form submission arrives as `.formResubmitted`. It is allowed only after **Send Again** in a confirmation that names the host; Cancel refuses the navigation and keeps the page. A page can cause this itself, such as through a script's history navigation, so the confirmation is treated like a website dialog: it goes through the tab's `WebPageDialogPresenter`, is only ever a sheet on the tab the user is looking at, and is taken away (and the navigation refused) whenever a website dialog would be. When it cannot be asked, because the tab is in the background, the window has a sheet, a review is running or another question is showing, the navigation is refused and the message bar says so. It is never an application-modal alert, which a page in a background tab could otherwise raise again and again.
- **Web content process.** If the process ends, the tab and address field stay usable, the placeholder offers Reload, and nothing reloads by itself.
- **Unsupported actions.** Downloads (a link marked for download, or a response WebKit cannot show) and other schemes get their own message, and leave the page as it is. There is no way to bypass a certificate error.

### Navigation policy

`WebPageNavigationPolicy` accepts HTTPS everywhere, and HTTP only for:

- `localhost`;
- IP literals in the loopback (127/8, `::1`), private (10/8, 172.16/12, 192.168/16, `fc00::/7`) and link-local (169.254/16, `fe80::/10`) ranges, and IPv4-mapped IPv6 forms of them;
- unqualified names, such as `devbox`;
- names under `.local`.

Hosts are parsed structurally, not matched as text: `localhost.example.com` and `10.0.0.1.example.com` are qualified names. Numeric hosts are read as WebKit's URL parser reads them, including shortened, octal and hexadecimal IPv4 forms (`0x7f.1` is 127.0.0.1, and `134744072` is 8.8.8.8), so a number cannot slip a public address through as an unqualified name. IPv6 zone identifiers are allowed. `.test`, `.localhost` subdomains and every other qualified name need HTTPS, even if they resolve to a local address. The policy describes what is supported; it is not a security boundary, since DNS decides where a name leads.

It applies to typed addresses, links, redirects, history navigation, new-window requests and restored entries. Addresses with a user name or password are refused everywhere. A refused destination is never rewritten or loaded some other way; the page stays and the message explains that the destination needs HTTPS. Frames inside a page may also show `about:`, `data:` and `blob:` content, which reaches no server. Subresources, fetches and WebSockets are governed by App Transport Security and WebKit's mixed-content rules instead.

Typed text without a scheme gets HTTPS, including local servers (`localhost:3000` becomes `https://localhost:3000`); HTTP must be typed. Text with spaces is refused: the field is not a search field.

### New windows

`javaScriptCanOpenWindowsAutomatically` is off, so WebKit asks for a new browsing context only for a user gesture. `webView(_:createWebViewWith:for:windowFeatures:)` then loads the request in the same tab, if the policy accepts it, and returns `nil`.

Only the page's own main frame may do this. A request from a frame inside the page would replace the whole page, which a frame may otherwise not do: an embedded frame, such as an advertisement sandboxed with `allow-popups` but without `allow-top-navigation`, could replace the page it is on. Such a request loads nothing, and the message bar says why.

### Devices

The camera and microphone are refused (`webView(_:decideMediaCapturePermissionsFor:initiatedBy:type:)` answers `.deny`). Without an answer, WebKit asks the user itself, and the app has no usage descriptions for those devices. File inputs do nothing, since the app does not implement the open panel delegate method, and geolocation has no usage description either.

### Website dialogs

- JavaScript alerts, confirmations and prompts are sheets on the window. Their title names the origin of the frame that asked, from `WKFrameInfo.securityOrigin`, as website content (`The website “https://example.com” says:`); the message is the informative text. Neither the page title nor the message can supply the origin. An origin WebKit does not give is labelled unknown.
- `WebPageDialogPresenter` shows a dialog only while the tab is selected in the active window, the window has no sheet, no application-modal window is up, and the directory is not reviewing a close or waiting for a tab's close approval. The active window is the key or main window, or, while the app has no main window, its frontmost window. Other requests are answered at once with the safe response (alerts acknowledged, confirmations cancelled, prompts without a value), and are not queued; no tab is selected to show them.
- A shown dialog is dismissed, and answered with the safe response, when a close review starts (patch 1's `directoryWillShowReview()`), when its tab is switched away from or closed, when its window closes and when the web content process ends. Every request is answered exactly once, including when the sheet's own late callback arrives after a dismissal. A question is shown on a later turn than its request; if the tab takes it away in between, or stops being the tab the user looks at, it is never shown. Dismissal neither closes nor navigates the page.

### Website data

Cookies and storage use `WKWebsiteDataStore.default()`, which is private to the app's bundle identifier; no sharing with Safari is promised. The data store is separate from tab restoration. A webpage tab's context menu offers **Clear Website Data…**, which asks first and then removes every record, for all sites, including those open in other tabs.

## Commands

- **New Webpage** in the **+** menu, and **File > New Webpage Tab** after New Shell Tab, with no default shortcut. Both open an empty tab.
- With file tabs off, the command offers **Enable Tabs and Open Webpage** and goes through patch 1's preference transition; Cancel does nothing.
- Patch 1's tab commands, close button and reordering work for webpage tabs. Webpage tabs do not move to a window of their own. Save and editor commands cannot reach a hidden file, and the inspector and status bar are empty while a webpage is selected (patch 1's contract). Copy, Paste and Select All act on the focused web view or address field through the responder chain.

## Close and restoration

- **Closing never asks**, whether the tab is empty or loaded. WebKit has no public, cancellable close check, and releasing a `WKWebView` does not run the page's `beforeunload` handler. Webpages therefore add a teardown but no approval to patch 1's close handling: a tab closes at once; a window close, Close All and quit run the window's existing review unchanged, and the web views are torn down only when it completes, so a cancelled review leaves every page loaded; turning tabs off closes them with the other tabs.
- **Archive.** A `webpage` entry in patch 1's ordered archive holds the tab's ID, the address of the page that was showing (or the restored address), if the navigation policy allows it, and its title. An empty tab is an entry without an address. Cookies, credentials, history, page contents, form values and address edits are never archived, and addresses are not logged.
- **Addresses are archived without their query and fragment.** Those parts often carry one-time secrets: sign-in codes (`?code=`), access tokens (`#access_token=`), reset and magic links. The saved application state is not encrypted, and **Load Webpage** would send such a code again. Keeping the query only for some sites would need a list of which parameters are safe, which the app cannot know, so the query is always dropped; a restored tab offers the page's scheme, host, port and path, and a page that needs its query must be navigated to again. The decoder drops them as well, from any archive that holds them.
- **Restoration.** A tab comes back in its place, with its title, as a placeholder that shows its address and a **Load Webpage** button. Nothing is loaded until the user asks, so restoring a folder window contacts no website, and history starts empty. The decoder treats entries as untrusted: an address that is not a string, cannot be parsed, or is refused by the policy skips the entry, an address with a query or fragment comes back without them, and a title that is not a string is dropped. Other entries are not affected, and builds without webpages skip the kind.

## Strings

The new strings are in `CotEditor/Localizables/WebPages.xcstrings`, in English only, synced with `scripts/sync-strings.sh`.

## Tests

- `WebPageNavigationPolicyTests` covers typed input (the default scheme, text that is not an address, other schemes, credentials), every local host form, IPv4 and IPv6 with zones and mapped addresses, numeric host forms, ports, deceptive suffixes, `.test` and `.localhost` subdomains, public HTTP and HTTPS for the same hosts, malformed numeric hosts and frame content.
- `WebPageSessionTests` drives the session with fake navigation tokens: titles, stale callbacks of older navigations, cancellations and Stop, retry eligibility (a paired GET, a POST, an ambiguous pairing, no decision, redirects of each kind), failures after commit, a failure without any page, the address following only the committed page, process termination, late callbacks after closing, the archive's fields (without queries and fragments) and the decoder's handling of damaged entries and queries, restored sessions, and the dialog origin label and safe responses.
- `DirectoryTabTests+WebPage` extends patch 1's serialized suite, because it changes the global preference and webpage prompts. It uses real WebKit against `WebPageTestServer`, a small HTTP server on a loopback address that counts requests per path and method (a second one on `::1` provides another origin). No test contacts another website. It covers mixed tabs without a file, the tabs-off prompt, titles and redirects, switching without reloading or losing history, an address being edited, a failed navigation keeping a form's value and Retry asking only for the failed page, a failed POST never being retried as POST or GET, the resubmission confirmation with request counts (Cancel sends nothing; going back never resends), refused links, redirects and typed public HTTP, popups without a gesture, process failure reloading nothing, closing never asking and a cancelled window close keeping every page, restoration in mixed order without a request before Load Webpage, dialogs naming a child frame's own origin, dialogs of a hidden tab and during a review answered safely, a pending dialog dismissed once before a review and when switching away, a dialog taken away before it shows never showing, the address staying the committed page's during a navigation that hangs (with `WebPageTestServer`'s `.hang` route) and following `pushState` and fragments, a failed first navigation showing the placeholder, resubmission never asked in a background tab and taken away when switching away or closing, a frame's new-window request loading nothing while the page's own does, the camera and microphone refused (asked directly with a real frame, since pages in these web views cannot reach the capture API), a closed tab's page unloaded and unable to navigate, Clear Website Data with its confirmation, and the app's `Info.plist` transport settings.

## Evidence

Environment: Xcode 27.0 (27A266a), macOS 27.0 (Darwin 27.0.0) on arm64, locale `en_NL`.

- **Export and application.** `scripts/export-patches.sh` wrote patches 1 to 3 from the workspace, and its verification applied every prefix to fresh clones: patch 3 is refused on plain upstream and on upstream with patch 1, and applies after patches 1 and 2. [Patch 4](04-remote.md) was then rebased onto this patch; its document has the results.
- **Focused tests per prefix** (`scripts/verify-patches.sh --workspace .work/CotEditor --test`, fresh clones): 58 tests in 3 suites after patch 1, 110 in 6 after patches 1 and 2, and 147 in 8 after patches 1 to 3, all passed.
- **Full test plan** (`scripts/build.sh --workspace --through webpage --test-all`): 287 tests in 43 suites passed.
- **Signing.** `scripts/check-signing.sh --workspace --through webpage` built an ad-hoc signed Release `CotEditor-Web-arm64.app`: hardened runtime on, no App Sandbox, no iCloud, only `arm64`, strict verification passes. `scripts/build.sh --workspace --through webpage --release --adhoc --arch x86_64` built `CotEditor-Web-x86_64.app`: only `x86_64`, `flags=0x10002(adhoc,runtime)`, and `codesign --verify --deep --strict` passes. It was not launched, since the build Mac is Apple Silicon.
- **Built transport settings.** The built `CotEditor-Web-arm64.app` has `NSAppTransportSecurity = { NSAllowsLocalNetworking = true }` and no other transport key; `onlyLocalNetworkingIsAllowed` checks the same in the test host.
- **Found while testing.** WebKit already brackets an IPv6 host in `WKSecurityOrigin.host`, so the origin label adds brackets only to a bare address. A test host that is not the active app has no key or main window, which led to the active-window rule above. A script's `location.reload()` of a page made by a POST form reloads it with GET in this WebKit, so it does not reach the resubmission confirmation; `WKWebView.reload()` and history navigation do. `navigator.mediaDevices` is not available to pages in these web views, so the capture refusal is defence in depth.

- **Hardening of the address, questions, frames, devices, teardown and archive** (workspace with every patch, uncommitted): `scripts/build.sh --checkout .work/CotEditor --test` passed 386 tests in 19 suites; a scratch tree of patches 1 to 3 with the same changes passed 180 tests in 8 suites.

**Mutation checks.** Each protection below was disabled on purpose, and its test failed:

| Protection disabled | Test that failed |
| --- | --- |
| Navigation generation (events of older navigations ignored) | `onlyTheNewestNavigationChangesTheState`, `stopEndsLoadingWithoutAFailure`, `processTerminationRetriesNothing`, `closedSessionsIgnoreLateCallbacks` |
| Keeping the page on a provisional failure (an error document loaded instead) | `aFailedNavigationKeepsTheFormAndRetriesOnlyItsOwnRequest`, `aFailedFormSubmissionIsNeverRetried` |
| Retry only for a paired GET | `onlyAPairedGETIsRetryable`, `aRedirectIsRetryableOnlyIfEveryRequestWas`, `aFailedFormSubmissionIsNeverRetried` |
| The `.formResubmitted` confirmation | `resubmittingAFormAsksFirst` |
| Structural host parsing (`localhost` as a first label) | `publicHTTPRequiresHTTPS(address:)` |
| Private IPv4 ranges only | `refusedDestinationsKeepThePage` |
| The policy on links and redirects | `refusedDestinationsKeepThePage` |
| The policy on restored entries | `archiveDecodingSkipsMalformedEntries` |
| Popups only for a user gesture | `refusedDestinationsKeepThePage` |
| Dialog suppression (selected tab, no review) | `dialogsOfHiddenTabsOrDuringAReviewAreAnsweredSafely` |
| Answering a dismissed dialog with the safe response | `dialogsOfHiddenTabsOrDuringAReviewAreAnsweredSafely` |
| The origin label from `WKFrameInfo` (the page's address instead) | `dialogsNameTheFrameThatAsked` |
| Explicit loading after restoration | `restoredWebPagesLoadNothingUntilAsked` |
| The committed address (`WKWebView.url` instead of the back-forward list) | `theAddressIsThatOfTheCommittedPage` |
| Clearing the address without a committed page, and no previous-page claim without a page | `aFailureWithoutAPageHasNoPreviousPage`, `theAddressFollowsTheCommittedPageOnly`, `aFailedFirstNavigationShowsThePlaceholder` |
| Both of the above together (the placeholder after a failed first load) | `aFailedFirstNavigationShowsThePlaceholder` |
| Resubmission through the presenter (asked directly instead) | `resubmissionIsAskedOnlyOnTheTabOnScreen` |
| A dialog taken away before it shows stays unshown | `aDialogTakenAwayBeforeItShowsNeverShows` |
| New windows only for the main frame | `framesCannotReplaceThePageThroughANewWindow` |
| Refusing the camera and microphone (method removed) | `camerasAndMicrophonesAreRefused` |
| Unloading a closed tab's page | `closingWebPagesNeverAsksAndACancelledCloseKeepsThem` |
| Refusing a closed tab's navigations | `closingWebPagesNeverAsksAndACancelledCloseKeepsThem` |
| Archiving without query and fragment | `archiveKeepsOnlyAnAllowedAddressAndTitle`, `archiveDecodingSkipsMalformedEntries` |
| Dropping query and fragment when decoding | `archiveDecodingSkipsMalformedEntries` |

These were run one at a time, each with only the tests it concerns.

With an error document whose base is `about:blank`, the policy itself refused the error document, so the first form of that check failed only `refusedDestinationsKeepThePage`; the error document now uses the failed address as its base.

**Not done:**

- Tests for how often the views update: that a hidden tab skips its view updates and the placeholder is made once is only covered by the suite still passing.
- Manual checks: keyboard focus, VoiceOver labels, resizing, page interaction, JavaScript dialogs and the resubmission confirmation as sheets, HTTPS against a real certificate, and the exact **+ > New Webpage** workflow.
- HTTPS and secure WebSocket tests: they need a certificate the test host trusts, and no test-only trust decision exists yet. A development server's WebSocket, a LAN address and a `.local` name were not tried against App Transport Security; only the built `Info.plist` was inspected.
- How WebKit handles `beforeunload` on navigation without the private UI delegate method was not recorded.
- The quit review across two windows with webpages was not tested separately; it is patch 1's and patch 2's unchanged review.
- On quit, patch 2 asks about running terminals before any window's review starts, so a website dialog still showing at that moment is dismissed only when its own window's review begins.

## Known limitations

- Websites cannot ask before their tab closes: closing a webpage tab, its window or the app never runs the page's `beforeunload` handler.
- A link that asks for a new window opens in the same tab, so sign-in flows that rely on a popup talking back to its opener (`window.opener`) do not work.
- Links in a frame of a page that ask for a new window do nothing.
- A restored tab offers its page without the address's query and fragment.
- A page whose resubmission is refused in the background shows a message; the user reloads it while its tab is showing to decide.
- Local HTTP covers only the host forms above. Development domains such as `.test` need HTTPS.
- No bookmarks, browser settings, split layout, preview of edited files, automatic refresh on save or downloads.
- Strings are English only.
