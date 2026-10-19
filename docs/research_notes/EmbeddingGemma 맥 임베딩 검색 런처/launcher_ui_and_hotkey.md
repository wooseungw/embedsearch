# Raycast-style launcher UI on macOS (⌥Space hotkey, floating panel, keyboard UX) and open-source launchers to learn from

Research date: 2026-10-13. GitHub star counts, licenses, and last-push dates were pulled live with `gh api` on that date. The GitHub API reports some licenses as "NOASSERTION"; where I read the LICENSE file myself, I say so.

OS context: macOS 27 "Golden Gate" shipped on 2026-09-14 ([MacRumors](https://www.macrumors.com/2026/09/10/macos-27-golden-gate-release-date/); [ithinkdiff](https://www.ithinkdiff.com/macos-27-golden-gate-release-date-compatibility/)). The research machine reports Darwin 25.6, which is macOS 26.x Tahoe. Anything below that is specific to macOS 15, 26 or 27 is labeled as such.

---

## Q1. Open-source Raycast/Alfred/Spotlight-like launchers: what they're built with, and whether any already do semantic/embedding search

### Takeaway
The most useful references for a native Swift launcher in 2026 are **Tinycast**, **Sol** and **Vicinae**:
- **Tinycast** (Swift/SwiftUI+AppKit, AGPL-3.0, about 8.4k stars, very active) is the most complete and the most current, and its docs cover IME handling.
- **Sol** (React Native macOS with a Swift host, MIT) is a smaller, permissively licensed Swift panel/hotkey example.
- **Vicinae** (C++/Qt with macOS Objective-C++ backends, GPL-3.0, about 10.2k stars) also runs on macOS now.

For web stacks, the main projects are **SuperCmd** (Electron 40 plus Swift helpers, MIT), **Asyar**/**Verve**/**Coco** (Tauri) and **Wox** (Go core with its own GPU UI).

None of the mainstream launchers I checked ships local embedding-based semantic search. The local-semantic-search apps that do exist (Sidekick, Khoj, screenpipe, Rem) are chat or RAG apps or screen recorders, not hotkey launchers, so a launcher with an embedding core would fill an open gap.

### Cited Findings

**Launcher survey (stars, license, last push, stack):**

| Project | Stars | License | Last push | Stack / notes | Source |
|---|---|---|---|---|---|
| abue-ammar/tinycast | 8,444 (repo created 2026-06-29) | AGPL-3.0 (from the LICENSE file; the API says NOASSERTION) | 2026-10-13 | Swift. "SwiftUI and AppKit, zero third-party dependencies, no Electron", under 100 MB RAM. Runs Raycast extensions rendered as native SwiftUI. Has clipboard history, file search, snippets, window management, AI chat, and Raycast config import. Requires macOS 26+. | [README](https://github.com/abue-ammar/tinycast), [LICENSE](https://github.com/abue-ammar/tinycast/blob/main/LICENSE) |
| ospfranco/sol | 3,168 | MIT | 2026-10-07 | TypeScript UI on React Native macOS with a Swift/ObjC native host. Clipboard manager, window manager, emoji picker, calendar, script runner, and more. Installs via `brew install --cask sol`. | [README](https://github.com/ospfranco/sol) |
| vicinaehq/vicinae | 10,240 | GPL-3.0 | 2026-10-13 | C++/QML (Qt) plus Objective-C++ macOS backends; macOS deployment target 14.4. Raycast-compatible React/TS extensions, plus clipboard history, file search, snippets, and a dmenu mode. | [README](https://github.com/vicinaehq/vicinae), [CMakeLists.txt](https://github.com/vicinaehq/vicinae/blob/main/CMakeLists.txt) |
| SuperCmdLabs/SuperCmd | 3,218 | MIT | 2026-07-11 | Electron 40, React 18, Vite, Tailwind, plus 11 Swift helper binaries. Ships a full `@raycast/api` / `@raycast/utils` compatibility shim and imports `.rayconfig` backups. Also has clipboard history (⌘1–9 quick paste), indexed file search, AI chat (including Ollama), and Korean localization. | [README](https://github.com/SuperCmdLabs/SuperCmd) |
| Wox-launcher/Wox | 27,505 | GPL-3.0 | 2026-10-13 | Go core that "owns the embedded Go UI under `wox.core/ui`, including native windows, focus lifecycle, widgets, and GPU rendering". Node.js and Python plugin hosts. Windows, macOS and Linux; about 150 MB memory. | [README](https://github.com/Wox-launcher/Wox), [AGENTS.md](https://github.com/Wox-launcher/Wox/blob/master/AGENTS.md) |
| Xoshbin/asyar | 904 | GPL-3.0 | 2026-10-12 | Tauri, Rust and Svelte 5. Extensions run in isolated iframes. Ships a black-box benchmark script against Raycast, measured on macOS 27.0.1. | [README](https://github.com/Xoshbin/asyar) |
| ParthJadhav/Verve | 859 | AGPL-3.0 | 2026-09-05 | Rust, Tauri and Svelte. Listed as a tauri-nspanel user. | [repo](https://github.com/ParthJadhav/Verve), [tauri-nspanel showcase](https://github.com/ahkohd/tauri-nspanel) |
| infinilabs/coco-app | 727 | MIT | 2026-08-06 | Tauri 2.0, React and Zustand. "AI Search and Assistant". Enterprise connectors; indexing lives in a separate coco-server repo. | [README](https://github.com/infinilabs/coco-app) |
| kunkunsh/kunkun | 1,305 | NOASSERTION | 2026-02-10 | TypeScript, Svelte and Rust (Tauri). Cross-platform, with an extension store, permission inspector and clipboard history. Activity has slowed. | [repo](https://github.com/kunkunsh/kunkun) |
| MatthiasGrandl/Loungy | 1,730 | MIT | archived (2025-10) | Rust on GPUI (Zed's GPU UI framework). The README says it is no longer in active development and points users to Gauntlet and Vicinae. | [README](https://github.com/MatthiasGrandl/Loungy) |
| project-gauntlet/gauntlet | 819 | MPL-2.0 | 2025-10-02 | Rust, with Deno-sandboxed TypeScript plugins and React through a custom reconciler (no Electron). | [README](https://github.com/project-gauntlet/gauntlet) |
| johnlindquist/kit (Script Kit SDK) | 4,191 | MIT | 2025-12-05 | TypeScript scripting SDK. The app repo is script-kit/app ("Script Kit App v3", 97 stars, last push 2025-12-09). | [kit](https://github.com/johnlindquist/kit), [app](https://github.com/script-kit/app) |
| oliverschwendener/ueli | 4,607 | MIT | 2026-10-12 | Electron/TypeScript. The macOS build is "neither signed nor notarized". | [README](https://github.com/oliverschwendener/ueli) |
| cerebroapp/cerebro | 8,564 | MIT | 2026-10-13 | Electron/JavaScript, with a plugin system. | [README](https://github.com/cerebroapp/cerebro) |
| Hammerspoon/hammerspoon | 16,268 | MIT | 2026-07-08 | Objective-C plus Lua automation. Its `hs.chooser` is a scriptable chooser UI, not a full launcher. | [repo](https://github.com/Hammerspoon/hammerspoon) |
| quicksilver/Quicksilver | 2,940 | Apache-2.0 | 2026-09-18 | Objective-C. The classic Mac launcher, still maintained. | [repo](https://github.com/quicksilver/Quicksilver) |
| albertlauncher/albert | 8,006 | NOASSERTION | 2026-09-27 | C++/Qt with some Objective-C++. | [repo](https://github.com/albertlauncher/albert) |
| spotter-application/spotter | 738 | GPL-3.0 | 2023-12-18 (inactive) | Dart/Flutter. | [repo](https://github.com/spotter-application/spotter) |
| twotwoba/LaunchX | 89 | Apache-2.0 | 2026-10-03 | Swift. | [repo](https://github.com/twotwoba/LaunchX) |
| ainto-labs/ainto-app | 31 | GPL-3.0 | 2026-09-18 | Swift plus Rust; clipboard history, snippets and AI commands. | [repo](https://github.com/ainto-labs/ainto-app) |
| alin23/Lunar | 5,718 | n/a | 2026-10-11 | **Not a launcher.** It controls external-monitor brightness ("Intelligent adaptive brightness for your external monitors"). | [repo](https://github.com/alin23/Lunar) |
| raycast/extensions | 7,781 | MIT | 2026-10-13 | The TypeScript/React extension monorepo for Raycast. Raycast itself is closed source. | [repo](https://github.com/raycast/extensions) |
| Flow-Launcher/Flow.Launcher | 15,763 | n/a | 2026-10-12 | C#, Windows only. Listed only for completeness. | [repo](https://github.com/Flow-Launcher/Flow.Launcher) |

**Raycast-extension compatibility has become a common OSS feature.** Vicinae ("compatible with the Raycast ecosystem… In-app integration with… the Raycast store") ([README](https://github.com/vicinaehq/vicinae)), SuperCmd ("existing Raycast extensions work without modification") ([README](https://github.com/SuperCmdLabs/SuperCmd)) and Tinycast ("runs real Raycast extensions, rendered as native SwiftUI") ([README](https://github.com/abue-ammar/tinycast)) all offer it.

**Building as a Raycast extension instead of a standalone app:**
- Raycast's store guidelines say: "Don't bundle heavy binary dependencies in the extension". Opaque binaries are disallowed, and any executables downloaded in the background must come from trusted locations, with hash verification ([Raycast: Prepare an extension for store](https://developers.raycast.com/basics/prepare-an-extension-for-store)).
- Raycast's `extensions-swift-tools` package (111 stars, pushed 2026-07-22) lets a React extension call Swift code compiled from a Swift executable target inside the extension, which gives access to native macOS APIs. It requires Xcode 16.3+ ([raycast/extensions-swift-tools](https://github.com/raycast/extensions-swift-tools)).
- The Raycast List API offers `onSearchTextChange` with a boolean `throttle` (the delay is undocumented), built-in fuzzy `filtering` that can be turned off, `isLoading`, and `isShowingDetail` for a right-hand detail/preview pane ([Raycast List API](https://developers.raycast.com/api-reference/user-interface/list)).

**Local semantic or embedding search apps on macOS:**
- **johnbean393/Sidekick** (3,319 stars, MIT, Swift, pushed 2026-09-30) is a native macOS chat app with llama.cpp. It does RAG over "experts" (files, folders, websites) ([README](https://github.com/johnbean393/Sidekick)), and its Swift package dependencies include a fork of `similarity-search-kit` ([Sidekick repo](https://github.com/johnbean393/Sidekick)). The upstream, ZachNagengast/similarity-search-kit, is "a Swift package providing on-device text embeddings and semantic search functionality for iOS and macOS"; it is Apache-2.0 with 536 stars, but its last push was 2024-06-04 ([repo](https://github.com/ZachNagengast/similarity-search-kit)).
  - Its UI is a chat window, not a Spotlight-style panel. I found no launcher-style global panel in its main search path. It does use `.nonactivatingPanel` and `.canJoinAllSpaces` in helper windows ([Sidekick source](https://github.com/johnbean393/Sidekick)).
- **khoj-ai/khoj** (37,669 stars, AGPL-3.0, Python plus TypeScript) is a self-hostable "AI second brain" with "advanced semantic search". It is a server/web app with desktop, Obsidian and Emacs clients, not a native hotkey launcher ([README](https://github.com/khoj-ai/khoj)).
- **screenpipe/screenpipe** (21,929 stars, "source-available", Rust/TS/Swift) records screen and audio and offers "search with ai… using natural language" ([README](https://github.com/screenpipe/screenpipe)). It uses tauri-nspanel for its panels ([tauri-nspanel showcase](https://github.com/ahkohd/tauri-nspanel)).
- **jasonjmcghee/rem** (2,490 stars, MIT, Swift, last push 2024-05) records the screen and offers keyword search. "Natural language search… via updating local vector embedding" is still an unchecked roadmap item ([README](https://github.com/jasonjmcghee/rem)).
- Smaller projects:
  - alpaim/vecDir: Tauri, Rust, React and SQLite, with local multimodal embeddings through an OpenAI-compatible API such as llama.cpp or LM Studio; 4 stars ([repo](https://github.com/alpaim/vecDir)).
  - vladmarian20005/EmbeddedFinder: Python, 18 stars ([repo](https://github.com/vladmarian20005/EmbeddedFinder)).
  - jiggersong/everythingsearch: a Python macOS semantic file search engine, 5 stars ([GitHub search](https://github.com/jiggersong/everythingsearch)).

**None of the launchers I grepped contain an embedding search.** I grepped the downloaded sources of Tinycast, SuperCmd, Vicinae and Sol for `embedding|NLEmbedding|cosine|sqlite-vec`. The only hits were Tinycast's Core ML dictation (Qwen ASR) model, not search ([QwenRecognizer.swift](https://github.com/abue-ammar/tinycast/blob/main/Tinycast/Features/Dictation/Helper/QwenRecognizer.swift)).
  - This still shows that a native Swift launcher can host Core ML models in-process.

**Tinycast file search:** the README says Search Files works "through Spotlight, with no index of our own" ([README](https://github.com/abue-ammar/tinycast)). The newer feature doc instead describes a "filename index, built from a whole-disk crawl and kept current from FSEvents. Spotlight is not involved", following fsearch ([file-search.md](https://github.com/abue-ammar/tinycast/blob/main/docs/features/file-search.md)).
  - The README and the feature doc disagree, so the README is probably stale.

**Apple's own competitor:** macOS 26 Tahoe Spotlight added Actions (App Intents), Quick Keys, clipboard history (off by default, cleared every 8 hours) and category browsing (⌘3 Actions, ⌘4 Clipboard) ([heise](https://heise.de/-10481334); [MacRumors Tahoe hidden features](https://www.macrumors.com/guide/macos-tahoe-hidden-features); [iGeeksBlog](https://www.igeeksblog.com/what-to-do-with-spotlight-in-macos-tahoe/)).

### Inferences
- **Which project to fork depends on the license you can accept:**
  - For a permissive base, Sol (MIT) is the cleanest native Swift example of a panel plus hotkey, but its UI is React Native.
  - Tinycast is the best pure SwiftUI/AppKit reference, but it is AGPL-3.0. Forking it makes your whole app AGPL; reading it for patterns does not.
  - Vicinae (GPL-3.0) and Wox (GPL-3.0) are copyleft as well.
- **Building only as a Raycast extension is a poor fit for an app whose core is a local embedding model.** The store guidelines discourage bundling heavy binaries, and a model weighs hundreds of MB. Downloading it at runtime from a trusted host with hash checks might be acceptable. Raycast also owns the hotkey and the UI, so you can't control IME handling or the panel.
- **A Raycast-API-compatible companion extension would still reach users.** It would talk to a local daemon, and it would run in Raycast, Vicinae, SuperCmd and Tinycast alike, since all of them implement the Raycast API.
- **Product gap:** no mature OSS launcher combines a Spotlight-style hotkey panel with on-device embedding search. Sidekick and Khoj do RAG behind a chat UI instead.

### Gaps
- I didn't check whether Albert and Kunkun currently ship signed macOS builds.
- Script Kit's v3 app status (Electron vs. another stack) is unconfirmed beyond "TypeScript".
- Ainto, Walter and LaunchX are too small to judge maturity.
- I could not find public specifics on Raycast's own closed-source implementation, such as its panel window level or IME handling.
- I didn't verify whether Raycast lets users assign a hotkey to a third-party extension command; this is likely, but I didn't fetch a source.

---

## Q2. Global hotkey on macOS: Carbon RegisterEventHotKey vs NSEvent global monitor vs CGEventTap; libraries; permissions; sandbox/App Store

### Takeaway
Use Carbon `RegisterEventHotKey` for the summon hotkey. Concretely, use `sindresorhus/KeyboardShortcuts`, or a thin wrapper like Tinycast's `HotKeyCenter`. It needs no permission prompt, works in the sandbox and on the Mac App Store, and is what Raycast-class apps use (Sol via HotKey, Vicinae, Tinycast, and Tauri's `global-hotkey`).

Reserve `CGEventTap` for things Carbon can't do: modifier-only or double-tap keys, the Hyper key, snippet expansion and media keys. A tap requires Input Monitoring (listen-only) or Accessibility (active filter). `NSEvent.addGlobalMonitorForEvents` for key events requires Accessibility, can't consume events, and is not a good primary hotkey mechanism.

### Cited Findings
- **sindresorhus/KeyboardShortcuts** (2,724 stars, MIT, pushed 2026-09-11) is "fully sandboxed and Mac App Store compatible". To "Does this package cause any permission dialogs?" the README answers "No." It uses Carbon APIs, which the README notes Apple never shipped modern replacements for. It does not support media keys because that "would not work for sandboxed apps" ([README](https://github.com/sindresorhus/KeyboardShortcuts)).
  - It includes a SwiftUI `KeyboardShortcuts.Recorder` and lets you declare an initial shortcut on a `Name`, e.g. `Self("…", initial: .init(.k, modifiers: [.command, .option]))` ([README](https://github.com/sindresorhus/KeyboardShortcuts)).
- **soffes/HotKey** (1,082 stars, MIT, last push 2024-12-29) "wraps the Carbon APIs for dealing with global hot keys". Usage: `HotKey(key: .r, modifiers: [.command, .option])` with `keyDownHandler` and `keyUpHandler` ([README](https://github.com/soffes/HotKey)). Sol uses it, with the default `mainHotKey = HotKey(key: .space, modifiers: [.command])` ([HotKeyManager.swift](https://github.com/ospfranco/sol/blob/main/macos/sol-macOS/managers/HotKeyManager.swift)).
- **MASShortcut** (cocoabits/MASShortcut, 1,546 stars, BSD-2-Clause) has been **archived** since its last push on 2022-10-18. It is outdated ([repo](https://github.com/cocoabits/MASShortcut)).
- **Tinycast** registers chord hotkeys with Carbon `RegisterEventHotKey` ([HotKeyCenter.swift](https://github.com/abue-ammar/tinycast/blob/main/Tinycast/Features/HotKeys/Service/HotKeyCenter.swift)). It uses `CGEvent.tapCreate` only for the Hyper key, modifier-only and double-tap gestures, snippet keyword expansion and a command-escape tap ([HyperKeyTap.swift](https://github.com/abue-ammar/tinycast/blob/main/Tinycast/Features/HotKeys/Service/HyperKeyTap.swift), [hotkeys.md](https://github.com/abue-ammar/tinycast/blob/main/docs/features/hotkeys.md)).
  - Its docs: "Carbon's dispatcher enters through an explicit `@MainActor` callback. Press and release handlers return `OSStatus` synchronously" ([hotkeys.md](https://github.com/abue-ammar/tinycast/blob/main/docs/features/hotkeys.md)).
- **Vicinae** on macOS registers with `RegisterEventHotKey` ([macos-global-shortcut-backend.cpp](https://github.com/vicinaehq/vicinae/blob/main/src/server/src/services/global-shortcuts/macos-global-shortcut-backend.cpp)) and uses a listen-only `CGEventTapCreate` for snippets ([macos-snippet-server.mm](https://github.com/vicinaehq/vicinae/blob/main/src/server/src/services/snippet/macos-snippet-server.mm)).
- **Tauri's `global-hotkey` crate** (tauri-apps/global-hotkey, Apache-2.0), which backs tauri-plugin-global-shortcut, calls `RegisterEventHotKey` for normal keys on macOS. It uses `CGEventTapCreate` only for media keys ([src/platform_impl/macos/mod.rs](https://github.com/tauri-apps/global-hotkey/blob/dev/src/platform_impl/macos/mod.rs)).
- **Electron-based SuperCmd** registers the launcher with Electron's `globalShortcut.register` (default `'Alt+Space'`). It shells out to Swift helpers built against `-framework Carbon` and uses `CGEvent.tapCreate` for hold-to-talk, the Hyper key, snippets and the emoji trigger ([main.ts](https://github.com/SuperCmdLabs/SuperCmd/blob/main/src/main/main.ts), [settings-store.ts](https://github.com/SuperCmdLabs/SuperCmd/blob/main/src/main/settings-store.ts), [input-monitoring-request.swift](https://github.com/SuperCmdLabs/SuperCmd/blob/main/src/native/input-monitoring-request.swift)).
- **Apple DTS on permissions (Quinn):** "Rather than using an `NSEvent` global event monitor, use a `CGEventTap`. For weird historical reasons, the former requires the Accessibility privilege whereas the latter requires the Input Monitoring privilege. The Input Monitoring privilege is easily available to sandboxed apps, and even apps published on the Mac App Store. It even has APIs to check for (`CGPreflightListenEventAccess`) and explicitly request (`CGRequestListenEventAccess`) that privilege" ([Apple Developer Forums 707680](https://developer.apple.com/forums/thread/707680)).
- **Which tap option triggers which prompt:** developer reports say a `.defaultTap` (active, can modify or consume events) triggers the Accessibility request, while `.listenOnly` triggers Input Monitoring. Holding Accessibility appears to cover Input Monitoring ([Apple Developer Forums 828052](https://developer.apple.com/forums/thread/828052)).
  - A macOS 15 report says the app doesn't reliably appear in the Input Monitoring list after `CGRequestListenEventAccess()` ([same thread](https://developer.apple.com/forums/thread/828052)). This is community-reported, not Apple-confirmed.
- **sindresorhus rejected a global-monitor fallback** for KeyboardShortcuts (2026): "`NSEvent.addGlobalMonitorForEvents` for key events requires Accessibility permission… Without it the monitor silently does nothing… and it would intermittently double-fire whenever Carbon does deliver the event (a global monitor is passive, it can't replace the Carbon handler)" ([PR #236](https://github.com/sindresorhus/KeyboardShortcuts/pull/236)).
- **Secure Input blocks some hotkeys:** "While secure input mode is active even non-sandboxed apps can not make use of shortcuts that consist of single keys, opt+key or shift+opt+key anymore"; "NSEvent.addGlobalMonitorForEvents never worked while secure input is active" (comments by the BetterSnapTool developer, [KeyboardShortcuts #176](https://github.com/sindresorhus/KeyboardShortcuts/issues/176)).

### Inferences
- **Recommended stack for a native app:** KeyboardShortcuts for the user-configurable ⌥Space summon (no permission prompt, sandbox-safe), and no CGEventTap unless you add modifier-only triggers.
- **Plan to fall back when ⌥Space can't be registered.** If you depend only on Carbon, have UI that detects a registration failure (e.g., error -9868) and prompts the user to pick another chord. Q3 explains when that happens.
- **Tauri and Electron end up on the same Carbon API**, so hotkey behavior is broadly the same across stacks. The real differences between stacks are in window and IME behavior (Q4, Q6).

### Gaps
- No Apple documentation formally lists which modifier combinations `RegisterEventHotKey` rejects on macOS 26 or 27. Evidence is forum and issue reports only.
- I did not verify whether macOS 27 changed the Input Monitoring prompt behavior.

---

## Q3. ⌥Space specifics: conflicts, Korean IME interaction, reliability

### Takeaway
⌥Space is the de facto launcher default: Raycast, Vicinae and SuperCmd all ship with it. Carbon registration of ⌥Space works on current macOS for both sandboxed and unsandboxed apps. The exception was macOS 15.0–15.1, which blocked Option-only and Option+Shift hotkeys in sandboxed apps; 15.2 lifted that.

The real risks are:
1. Other apps claiming ⌥Space. The **ChatGPT/Codex unified desktop app registers ⌥Space for "Show Pet / Mini", and as of 2026-09 users cannot disable it**. Claude Desktop also uses ⌥Space for its Quick Launcher, and Siri's "hold ⌥Space" option can collide.
2. Losing the user's ⌥Space non-breaking-space typing.
3. IME interplay. Option+**letter** hotkeys intermittently fail because the input method consumes them, and Secure Input blocks Option-only hotkeys.
4. Korean composition bugs **inside** the summoned window. This is especially likely with Electron webviews: Claude Desktop's ⌥Space launcher dropped Hangul jamo until a fix.

### Cited Findings
**Defaults in other launchers:**
- Raycast's manual: "On Mac, the default is `⌥ Space`." It warns: "If you use, or have previously used, multiple languages on your Mac, you'll likely have a conflicting shortcut" (Input Sources). It also warns that Siri may default to holding ⌘Space or ⌥Space: "When Raycast shares that shortcut, you might notice a slight delay when toggling the main window" ([Raycast Manual – Settings](https://manual.raycast.com/settings.md)).
- Vicinae's config default is `toggle = "alt+space"` ([config.hpp](https://github.com/vicinaehq/vicinae/blob/main/src/server/src/config/config.hpp)). SuperCmd's default is `globalShortcut: 'Alt+Space'` ([settings-store.ts](https://github.com/SuperCmdLabs/SuperCmd/blob/main/src/main/settings-store.ts)). Sol defaults to ⌘Space ([HotKeyManager.swift](https://github.com/ospfranco/sol/blob/main/macos/sol-macOS/managers/HotKeyManager.swift)).
- Alfred: sources disagree on the default hotkey. The official help says only "Space" without naming a modifier; older sources say ⌥Space ([search summary of Alfred help](https://alfredapp.com/help/general), [Cult of Mac](https://www.cultofmac.com/?p=223389)). Treat the Alfred default as unconfirmed.

**macOS 15 Option-only restriction (historical, now lifted):**
- In macOS 15.0 and 15.1, `RegisterEventHotKey` with only Option or Option+Shift modifiers failed with `-9868`. An Apple Frameworks Engineer called it "an intentional change in macOS Sequoia to limit the ability of key-logging malware… shift+option can be used to generate alternate characters in passwords, such as Ø… macOS Sequoia now requires that a hotkey registration use at least one modifier that is not shift or option" ([Apple Developer Forums 763878](https://developer.apple.com/forums/thread/763878?page=2); [KeyboardShortcuts #176](https://github.com/sindresorhus/KeyboardShortcuts/issues/176)).
- The restriction applied to **sandboxed** apps: "The sandbox is the differentiating factor here" ([#176 comments](https://github.com/sindresorhus/KeyboardShortcuts/issues/176)).
- **macOS 15.2 lifted it.** KeyboardShortcuts 2.2.4 (2024-12-13) shipped "Reintroduce Option key shortcuts for macOS 15.2 and later" ([release 2.2.4](https://github.com/sindresorhus/KeyboardShortcuts/releases/tag/2.2.4)); a user confirmed "These shortcuts now work again on macOS 15.2!" ([#176](https://github.com/sindresorhus/KeyboardShortcuts/issues/176)); see also [Eternal Storms blog (updated for 15.2)](https://blog.eternalstorms.at/2024/09/23/keyboard-shortcuts-using-option-and-or-shift-modifiers-only-no-longer-allowed-on-macos-sequoia/).
  - A November 2025 forum report says the problem returned for one user who was also remapping with Karabiner. That is unconfirmed ([search summary of forum thread 763878](https://developer.apple.com/forums/thread/763878?page=2)).
- **⌥Space specifically:** a user reported opt+space not firing while ⌘⌥K worked. sindresorhus answered: "I just tried turning off sandboxing in the example app… and Option+Space works there… Most likely, something else on your system is taking the shortcut" ([KeyboardShortcuts #189](https://github.com/sindresorhus/KeyboardShortcuts/issues/189), Nov 2024).

**IME interaction (macOS 26):**
- KeyboardShortcuts #235 (filed on macOS 26.3, 2026-03) reports: "Shortcuts using `option + letter`… stop working intermittently. `option + number` works reliably." The reporter's hypothesized cause is that "`option + letter` combos… are processed by the Text Services Manager **before** Carbon hotkey events are dispatched", so it "depends on the active application's IME mode" ([#235](https://github.com/sindresorhus/KeyboardShortcuts/issues/235)).
  - The maintainer's answer: "there's no permission-free public API to reliably intercept Option + letter before the text input layer" ([PR #236](https://github.com/sindresorhus/KeyboardShortcuts/pull/236)).
- **Claude Desktop's Quick Launcher (⌥Space, Electron)** dropped Korean jamo during composition with the 2-Set Korean IME. Example: "오늘 무엇을 도와드릴까요?" came out as "오ㄹ 무ㅅㅡ 도ㅏㅡㅣ까?". It happened only in the overlay, not the main window. The reporter linked it to Electron CJK bugs when windows are focused programmatically. A user workaround was `killall imklaunchagent`, and a commenter reported it fixed in Claude Desktop 1.7196.0 ([anthropics/claude-code #21382](https://github.com/anthropics/claude-code/issues/21382)).
  - The related Electron bug: "When a BrowserWindow is not in the front… call `window.show()` in the Tray click event… one can not use Chinese(Japanese,Korea) input IME on this window" ([electron #32307](https://github.com/electron/electron/issues/32307)).

**Conflicts with other apps:**
- **ChatGPT/Codex (unified ChatGPT.app, v26.924, 2026-09-29):** "registers `Option+Space` as a global shortcut for Show Pet / Mini… cannot be changed or disabled… conflicts with Raycast" ([openai/codex #49201](https://github.com/openai/codex/issues/49201)).
  - Earlier, ⌥Space opened ChatGPT Quick Chat. After the July 2026 ChatGPT/Codex unification, users reported that Quick Chat was gone ([openai/codex #31925](https://github.com/openai/codex/issues/31925); [#47460](https://github.com/openai/codex/issues/47460)).
  - The "ChatGPT uses ⌥Space by default" premise therefore still holds in practice, but the bound feature has changed (Pet/Mini rather than Quick Chat).
- Another report: "KeepassXC blocking option+space keypresses on macOS" ([keepassxc #13240](https://github.com/keepassxreboot/keepassxc/issues/13240), 2026-04).

**Non-breaking space and input-source shortcuts:**
- **⌥Space normally types U+00A0 (non-breaking space)** in macOS text fields ([UIUC TIL](https://til.acm.illinois.edu/macos/insert-a-non-breaking-space-character/); [PoliteMail help](https://help.politemail.com/help/how-can-i-add-a-space-that-will-not-create-a-line-break)). A Dorico user found ⌥Space stopped producing its normal behavior after assigning it to Raycast ([Steinberg forum](https://forums.steinberg.net/t/non-breaking-space-wont-work/940100)).
- **Korean input source switching:** Apple's Korean input method guide lists ⌃Space (previous input source) and ⌃⌥Space (next input source), plus an opt-in Caps Lock toggle between Korean and ABC ([Apple Korean Input Method User Guide](https://support.apple.com/guide/korean-input-method/korean-hangul-input-method-user-guide-him001/mac)).
  - ⌥Space itself is not a default input-source shortcut, but ⌃⌥Space is adjacent to it.

**Tinycast's input-source pattern:** "Input-source switching is a palette session. The source active at summon time is captured before the panel becomes key, the configured source is applied through `PalettePanel.fieldEditorContext`, and the captured source is restored on hide… Never applied globally: the panel does not activate, so a global switch would land on whichever app is still frontmost" ([palette.md](https://github.com/abue-ammar/tinycast/blob/main/docs/features/palette.md)).

### Inferences
- **The summon itself should be reliable** for a non-sandboxed, Developer-ID app on macOS 26 or 27 with the Korean IME active. In #235 the failing combos were Option+**letter**. Space doesn't go through Hangul jamo composition, and launchers with large installed bases (Raycast, Vicinae, SuperCmd) default to ⌥Space. This is an inference, not a verified test: I found no report specifically of ⌥Space failing under the Korean IME.
- **Do conflict detection at startup.** If registration fails, or if the ChatGPT app is installed, tell the user, and offer ⌃Space-free alternatives such as ⌘⌥Space or a double-tap modifier via CGEventTap.
- **Users lose NBSP typing.** Registering ⌥Space globally takes it away from every app. Mention this in onboarding.
- **Consider Tinycast's input-source pattern for Korean users.** Applying a preferred source to the panel's field editor context only (Korean or English) at summon, then restoring it on hide, avoids "typed in the wrong layout" errors without changing the frontmost app's input source.
- **Test Hangul composition in the summoned panel.** Electron overlays are a known risk. Native NSTextField/NSTextView in an NSPanel avoids the Chromium path entirely.

### Gaps
- I found no authoritative test of ⌥Space hotkeys under Secure Input (e.g., while a password field is focused) on macOS 26 or 27. By the #176 comments, Option-only hotkeys are blocked under Secure Input; whether that includes ⌥Space was not explicitly tested.
- I don't know what character ⌥Space produces under the Korean 2-Set layout.
- I found no Apple documentation of the Sequoia restriction or its 15.2 reversal, only forum and DTS replies.
- I couldn't verify the Claude Desktop changelog entry for 1.7196.0; the only evidence is the comment in the issue.

---

## Q4. Window: NSPanel non-activating floating panel, Spaces/full-screen, positioning, dismissal, agent app, vibrancy/Liquid Glass, SwiftUI hosting

### Takeaway
The proven recipe is the same in Sol, Tinycast and the multi.app write-up:
- An `NSPanel` subclass with `.nonactivatingPanel` in the **initializer's** style mask, `canBecomeKey = true`, a floating-or-higher level, and `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`.
- Transparent background with `NSVisualEffectView`, or `NSGlassEffectView` on macOS 26+, hosting SwiftUI through `NSHostingView`.
- Hide on `resignKey` or `windowDidResignKey`, and on Esc via `cancelOperation`.
- An agent app (`LSUIElement`, activation policy `.accessory`), launched with the `.prohibited`→`.accessory` trick so it never steals focus.
- Position on the target screen's `visibleFrame`, about 18–30% from the top, growing downward.

### Cited Findings
- **Apple:** `.nonactivatingPanel` means "The window is a panel or a subclass of [NSPanel] that does not activate the owning app" ([Apple docs: nonactivatingPanel](https://developer.apple.com/documentation/appkit/nswindow/stylemask-swift.struct/nonactivatingpanel)). It is "valid only for an instance of NSPanel or its subclasses; not valid for a window" ([Apple docs: NSNonactivatingPanelMask](https://developer.apple.com/documentation/appkit/nsnonactivatingpanelmask)). `.canJoinAllSpaces`: "The window can appear in all spaces. The menu bar behaves this way" ([Apple docs](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/canjoinallspaces)).
- **Tinycast `PalettePanel` (macOS 26+):**
  - `styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel]`, `isFloatingPanel = true`, `level = .palette`, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`.
  - `isOpaque = false`, `backgroundColor = .clear`, `hasShadow = true`, `animationBehavior = .none`, `isReleasedWhenClosed = false`.
  - `NSHostingView(rootView:)` with `hosting.sizingOptions = []`, commented "The controller owns the frame; without this the top edge drifts on the swap".
  - `canBecomeKey` and `canBecomeMain` return `true`; the latter so "Liquid Glass remains active" ([PalettePanel.swift](https://github.com/abue-ammar/tinycast/blob/main/Tinycast/Palette/PalettePanel.swift)).
  - `.palette` is a custom level: `NSWindow.Level(rawValue: NSWindow.Level.modalPanel.rawValue + 1)` ([WindowLevel.swift](https://github.com/abue-ammar/tinycast/blob/main/Tinycast/Platform/WindowLevel.swift)).
  - It shows with `makeKeyAndOrderFront` plus `orderFrontRegardless` ([PaletteWindowController.swift](https://github.com/abue-ammar/tinycast/blob/main/Tinycast/Palette/PaletteWindowController.swift)).
  - It runs as an agent: `LSUIElement` in Info.plist ([Info.plist](https://github.com/abue-ammar/tinycast/blob/main/Tinycast/Info.plist)) and `NSApp.setActivationPolicy(.accessory)` ([AppCore.swift](https://github.com/abue-ammar/tinycast/blob/main/Tinycast/App/AppCore.swift)).
- **Tinycast placement:** it anchors on the "display to anchor to; never `NSScreen.main`, which follows the focused window". That is either `NSScreen.underCursor` or `NSScreen.primary`, depending on a setting ([PaletteWindowController.swift](https://github.com/abue-ammar/tinycast/blob/main/Tinycast/Palette/PaletteWindowController.swift)). `paletteTopMarginFraction = 0.18`, described as the "Fraction of visible height above the palette's top edge; it grows downward" ([Theme.swift](https://github.com/abue-ammar/tinycast/blob/main/Tinycast/DesignSystem/Theme.swift)).
- **Tinycast Liquid Glass:** it wraps `NSGlassEffectView` in an `NSViewRepresentable` and uses SwiftUI `.glassEffect(.regular, in: shape)` in many components ([GlassEffectView.swift](https://github.com/abue-ammar/tinycast/blob/main/Tinycast/DesignSystem/GlassEffectView.swift)).
- **Vicinae** looks up `NSClassFromString(@"NSGlassEffectView")` at runtime for macOS liquid glass ([macos-chrome-attached.mm](https://github.com/vicinaehq/vicinae/blob/main/src/server/src/ui/quick/macos-chrome-attached.mm)) and sets the activation policy to Accessory ([app-platform-macos.mm](https://github.com/vicinaehq/vicinae/blob/main/src/server/src/app-platform-macos.mm)).
- **Sol `Panel`:**
  - `styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel]`, `level = .floating`, inserts `.fullScreenAuxiliary` and `.canJoinAllSpaces`, `titleVisibility = .hidden`, `titlebarAppearsTransparent = true`, `isMovableByWindowBackground = true`.
  - The content view is an `NSVisualEffectView` with `material = .headerView`, `blendingMode = .behindWindow`, `state = .active`.
  - `windowDidResignKey` → `PanelManager.shared.hideWindow()` ([Panel.swift](https://github.com/ospfranco/sol/blob/main/macos/sol-macOS/views/Panel.swift)).
  - Position: `x = visibleFrame.midX - width/2`, `y = visibleFrame.midY - height + visibleFrame.height*0.3` ([PanelManager.swift](https://github.com/ospfranco/sol/blob/main/macos/sol-macOS/managers/PanelManager.swift)). Sol is also an `LSUIElement` agent ([Info.plist](https://github.com/ospfranco/sol/blob/main/macos/sol-macOS/Info.plist)).
- **multi.app, "Nailing the activation behavior of a Spotlight/Raycast-like command palette"** (Art Lasovsky, 2024-02-14):
  - "Setting `LSUIElement`… removes the Dock icon at launch. However, the app still steals focus." The fix is to set `.prohibited` in `applicationWillFinishLaunching`, then `.accessory` in `applicationDidFinishLaunching`.
  - A plain NSWindow can't be interacted with until it is clicked; NSPanel plus `.nonactivatingPanel` fixes that. Their panel uses `[.closable, .titled, .nonactivatingPanel]` and `level = .modalPanel`.
  - Override `resignKey()` → `close()`, `cancelOperation(_:)` → `close()` (Esc), and `close()` → `super.close(); NSApp.hide(self)` to return focus to the previous app ([multi.app blog](https://multi.app/blog/nailing-the-activation-behavior-of-a-spotlight-raycast-like-command-palette)).
- **Cindori "Make a floating panel in SwiftUI for macOS"** (2022-06-01; **dated**):
  - Panel setup: `.nonactivatingPanel, .titled, .resizable, .closable, .fullSizeContentView`, `isFloatingPanel = true`, `level = .floating`, `.fullScreenAuxiliary`, `hidesOnDeactivate = true`, `animationBehavior = .utilityWindow`.
  - `resignMain()` → `close()`, and `canBecomeKey`/`canBecomeMain` → true.
  - SwiftUI content goes through `NSHostingView`, with an `NSVisualEffectView` representable (`.sidebar`, `.behindWindow`) ([cindori.com](https://cindori.com/developer/floating-panel)).
  - Its coordinator only applies `material` on update, and the `onChange` API usage predates current SDKs (per the fetch summary).
- **NSGlassEffectView (macOS 26+)**, from third-party evidence:
  - It has no opacity control, so honoring Reduce Transparency means substituting opaque content yourself.
  - Borderless windows using it need a `canBecomeKeyWindow` override ([macos-liquid-glass crate docs](https://docs.rs/macos-liquid-glass)).
  - Rust wrappers resolve the class at runtime and fall back to NSVisualEffectView before macOS 26 ([rio-window glass.rs](https://docs.rs/crate/rio-window/0.5.14/source/src/platform_impl/macos/glass.rs)).
  - `tauri-apps/window-vibrancy` exposes `apply_liquid_glass` for macOS 26+; its `.interactive(true)` option (`NSGlassEffectView.effectIsInteractive`) "requires macOS 27 or newer" ([window-vibrancy README](https://github.com/tauri-apps/window-vibrancy)).

### Inferences
- **Starter configuration (Swift):**
  - An `NSPanel` subclass created with `[.borderless or .titled, .fullSizeContentView, .nonactivatingPanel]`.
  - `isFloatingPanel = true`, `level = .modalPanel` or higher (above floating windows), `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`, `hidesOnDeactivate = false`, `isReleasedWhenClosed = false`, a clear background and a shadow.
  - `canBecomeKey = true`. Hide on `resignKey`, Esc and Enter-after-open.
  - `LSUIElement` plus the `.prohibited`→`.accessory` launch trick.
  - A glass or visual-effect background clipped to about 16–26pt corners. Tinycast notes a 26pt corner ([Theme.swift](https://github.com/abue-ammar/tinycast/blob/main/Tinycast/DesignSystem/Theme.swift)).
  - Anchor the top edge so the panel grows downward as results arrive.
- **Choosing the screen:** use the screen under the cursor or the primary screen, not `NSScreen.main`, so the panel opens where the user is looking (Tinycast's rationale).

### Gaps
- I couldn't confirm the private `_setPreventsActivation` workaround, or whether setting `.nonactivatingPanel` after init is broken on macOS 26/27. Search found nothing authoritative. Safest is to pass the mask in `init`, as every example does.
- `NSGlassEffectView`'s Apple reference page wasn't fetched; details above come from third-party code.

---

## Q5. Keyboard UX: list navigation, Enter, ⌘+number, Tab, preview pane, search-as-you-type vs Enter, Korean IME composition

### Takeaway
Copy Raycast and Alfred conventions:
- ↑/↓ (plus ⌃N/⌃P) to move, ↵ to open, ⌘↵ or ⌘K for secondary actions, ⌘1–9 to act on the Nth result, Tab for completion or mode switch, a right-hand detail pane, and Esc to pop or close.

For Korean input, **gate search triggers and key handling on `hasMarkedText()`**:
- Treat the query as "composing" while marked text exists.
- Let Backspace and Enter go to the IME during composition.
- Don't run a search, or don't execute an action, on the Enter that only commits a syllable.

For the user's "search on Enter **and** while typing" requirement: run a cheap lexical or prefix pass on every committed change, run the embedding search debounced (or throttled, as Raycast does), and force a full semantic search on Enter.

### Cited Findings
- **Alfred's cheatsheet:** "⌘ # Action the # item directly [1-9]"; "⇧ / ⌘Y Preview in Quick Look" ([Alfred Cheatsheet](https://support.alfredapp.com/cheatsheet)). Tab autocompletes, per a third-party list ([pie-menu Alfred shortcuts](https://www.pie-menu.com/shortcuts/alfred)).
- **Raycast List API:**
  - `onSearchTextChange` (setting it implicitly disables built-in filtering).
  - `throttle`: "whether the `onSearchTextChange` handler will be triggered on every keyboard press or with a delay".
  - `isLoading` (a loading bar under the search field) and `isShowingDetail` (a right-side detail area).
  - `selectedItemId` and `onSelectionChange`, plus `searchBarAccessory` (a dropdown opened with ⌘P) ([Raycast List API](https://developers.raycast.com/api-reference/user-interface/list)).
- **Ueli:** "Cmd+K" opens additional actions, which you navigate with the arrow keys and invoke with Enter; Escape closes them ([Ueli README](https://github.com/oliverschwendener/ueli)). SuperCmd's clipboard history uses ⌘1–9 quick-paste ([SuperCmd README](https://github.com/SuperCmdLabs/SuperCmd)).
- **Tinycast keyboard handling:**
  - ⌃N/⌃P/⌃F/⌃B are rewritten as arrow keys, resolved "Through the ASCII-capable layout: an IME must not move ⌃N off its physical key". In other words, Emacs-style keys are resolved via the ASCII layout so they work while the Korean IME is active.
  - Menu navigation keys (arrows, Return, keypad Enter, Escape, Tab) are intercepted in `sendEvent`, with a bare-Backspace step-back ([PalettePanel.swift](https://github.com/abue-ammar/tinycast/blob/main/Tinycast/Palette/PalettePanel.swift)).
  - "Tab rings the three surfaces… launcher → AI chat → clipboard → launcher", unless the screen or the selected row claims Tab for argument fields ([palette.md](https://github.com/abue-ammar/tinycast/blob/main/docs/features/palette.md)).
- **Tinycast IME composition (key pattern):**
  - "An IME composes into the field editor's own storage, so the bound `query` stays empty for the whole romanisation." `PalettePanel` publishes `hasMarkedText()` as `PaletteState.isComposing`.
  - The placeholder is hidden while composing, and "`PalettePanel.sendEvent` asks the editor's `hasMarkedText()` itself and lets Backspace through to the IME while a composition is in flight."
  - The observation "watches `NSTextView.didChangeSelectionNotification`" because "Selection is the only notification a marked-text change posts; `didChange` waits for commit" ([palette.md#ime-composition](https://github.com/abue-ammar/tinycast/blob/main/docs/features/palette.md); [PalettePanel.swift](https://github.com/abue-ammar/tinycast/blob/main/Tinycast/Palette/PalettePanel.swift)).
  - Root key handling bails out when composing: `guard !vm.isEditingField, !vm.isComposing else { return .ignored }` ([RootPaletteView.swift](https://github.com/abue-ammar/tinycast/blob/main/Tinycast/Palette/RootPaletteView.swift)). The calculator also checks `!core.palette.isComposing` ([CalculatorCoordinator.swift](https://github.com/abue-ammar/tinycast/blob/main/Tinycast/Features/Calculator/UI/CalculatorCoordinator.swift)).
- **Apple:** `NSTextInputClient.hasMarkedText()` "Returns a Boolean value indicating whether the receiver has marked text" ([Apple docs](https://developer.apple.com/documentation/appkit/nstextinputclient/hasmarkedtext())).
- **Web-stack IME pitfalls (Tauri/Electron UIs):**
  - MDN: `isComposing` can be false on the keydown that starts or ends a composition. The recommended guard also checks `keyCode === 229` ([MDN keydown](https://developer.mozilla.org/en-US/docs/Web/API/Document/onkeydown)).
  - Mozilla's bug discussion notes that on macOS, Safari's Korean IME "does not use composition string" and that browsers order events differently ([Mozilla bug 1529467](https://bug635044.bugzilla.mozilla.org/show_bug.cgi?id=1529467)).
  - Warp: the "last composing character is dropped when pressing Enter" with the Korean IME ([warp #8919](https://upd.dev/warpdotdev/warp/issues/8919)).
  - Claude Code: Korean characters were invisible during composition ([claude-code #22732](https://github.com/anthropics/claude-code/issues/22732)).

### Inferences
- **Recommended search pipeline:**
  1. On each *committed* text change, when `hasMarkedText()` is false, run instant lexical matching: app names, recent items, filename prefix.
  2. Run the embedding query debounced at roughly 150–300 ms after the last committed change. Cancel stale tasks with Swift structured concurrency.
  3. On Enter, if a composition is active, let the IME commit, then run the semantic search immediately. Don't also open the selected item on that same keypress.
  4. Show a progress indicator (like Raycast's `isLoading`) while embeddings compute.
- **Decide whether the in-progress syllable counts as part of the query.** For Korean, consider optionally including the marked text (read `string` plus the marked range) in the *lexical* preview pass, so results don't lag one syllable behind. Keep the embedding pass on committed text only.
- **Prefer AppKit text input over SwiftUI `TextField` here.** Use `NSTextField` with its field editor (as Tinycast does), or an `NSTextView` subclass. Pure SwiftUI `TextField` bindings don't expose marked-text state, and `onSubmit` can fire on the composition-committing Enter.

### Gaps
- I didn't find a primary source that tests SwiftUI `TextField.onSubmit` behavior with Korean marked text on macOS 26/27.
- The debounce interval is a heuristic; I found no benchmark data on it.

---

## Q6. Tauri and Electron routes vs native Swift: pitfalls and trade-offs for a local-embedding-model app

### Takeaway
All three stacks register the hotkey through Carbon, so they're on par there. They differ in four areas:
- **Window semantics.** Native gets a true non-activating NSPanel. Tauri gets one through `tauri-nspanel`. Electron's `type: 'panel'` floats over full-screen apps, but has a history of stealing focus from the previous app.
- **IME correctness.** Native is most robust. Electron overlays have documented CJK composition bugs.
- **Footprint.** Tinycast runs under 100 MB; Wox about 150 MB. Electron bundles Chromium.
- **ML runtime integration.**

For a Raycast-quality, Korean-friendly, Apple-Silicon-only app whose core is a local embedding model, native Swift (SwiftUI inside an AppKit NSPanel) is the strongest choice. Tauri with tauri-nspanel is a reasonable second choice if a Rust or web team prefers it.

### Cited Findings
**Tauri:**
- **tauri-nspanel** (ahkohd, 427 stars, Apache-2.0, pushed 2026-10-08, crate `tauri-nspanel = "2.1"`) converts or creates Tauri windows as NSPanels through the `tauri_panel!` macro (`can_become_key_window: true, is_floating_panel: true`) and `PanelBuilder` with `.level(PanelLevel::Floating)`, `show_and_make_key()` and so on. Showcased users include screenpipe, Cap, Handy, Coco, Verve, Asyar and EcoPaste ([README](https://github.com/ahkohd/tauri-nspanel)).
- **tauri-plugin-spotlight** (zzzze, 68 stars, last push 2025-01): hotkey show/hide, "automatically hide when losing focus", multi-display support, and "reactivate the previously active window upon hiding" (macOS) ([README](https://github.com/zzzze/tauri-plugin-spotlight)). It is small and may be stale.
- **window-vibrancy** (tauri-apps, 1,038 stars, pushed 2026-10-05): `apply_vibrancy(&window, NSVisualEffectMaterial::HudWindow, …)` on macOS, and `apply_liquid_glass` for macOS 26+ ([README](https://github.com/tauri-apps/window-vibrancy)).
- **Tauri config:** `macOSPrivateApi` "Enables the transparent background API and sets the `fullScreenEnabled` preference to `true`", and is a "No-op in Tauri 2.12.1+ because the APIs are always enabled now" ([Tauri config reference](https://v2.tauri.app/reference/config/)).
- **Tauri global shortcuts:** the backing `global-hotkey` crate uses `RegisterEventHotKey` on macOS ([global-hotkey macOS impl](https://github.com/tauri-apps/global-hotkey/blob/dev/src/platform_impl/macos/mod.rs)).

**Electron:**
- **BrowserWindow `type`:** "On macOS, possible types are `desktop`, `textured`, `panel`… The `panel` type enables the window to float on top of full-screened apps." There are also `hiddenInMissionControl` and `vibrancy` options ([Electron BaseWindowOptions](https://www.electronjs.org/docs/latest/api/structures/base-window-options)).
- **Focus stealing:** electron #35815 ("NSWindow does not support nonactivating panel styleMask") reports that `type: "panel"` makes the "Previous window [lose] focus". A workaround stopped working on Sonoma (2023-10), and comments in 2024 still asked for help ([electron #35815](https://github.com/electron/electron/issues/35815)).
- **`setVisibleOnAllWorkspaces(…, { visibleOnFullScreen: true })`** transforms the process type, mimicking `app.dock.hide()`. `skipTransformProcessType` was added to avoid that ([Electron commit #27200](https://ayakael.net/mirrors/electron/commit/444ad26f89fbf32696721a2270b54c0fcd8cb8b3); [#24956](https://ayakael.net/mirrors/electron/commit/53668445bac8a9cd602300fe13f57bd2c01e8035)).
- **SuperCmd's production Electron launcher** shows the workarounds:
  - It uses `type: 'panel'`, `hiddenInMissionControl: true`, `fullscreenable: false`, `transparent: true`, `vibrancy: false` (custom glass instead), and `acceptFirstMouse: true` ("Without this, macOS eats the first mouse-down on the panel to activate the window").
  - It calls `setVisibleOnAllWorkspaces(false, { visibleOnFullScreen: true, skipTransformProcessType: true })` with the comment "Avoid the dock/process-type transform for the launcher panel so Mission Control keeps it on the active Space".
  - It notes: "Do NOT call app.dock.hide() here. Hiding the dock before the window is loaded and shown prevents macOS from granting the app foreground status, causing the window to never appear on first launch" ([main.ts](https://github.com/SuperCmdLabs/SuperCmd/blob/main/src/main/main.ts)).
- **Electron IME:** CJK IME failures occur when a window is shown programmatically from a Tray click ([electron #32307](https://github.com/electron/electron/issues/32307)). Claude Desktop's ⌥Space Electron launcher had Korean composition loss until a fix ([claude-code #21382](https://github.com/anthropics/claude-code/issues/21382)).

**Footprint and stack examples:**
- Tinycast (native) advertises "under 100 MB of RAM" ([README](https://github.com/abue-ammar/tinycast)), and Wox about 150 MB ([README](https://github.com/Wox-launcher/Wox)).
- Asyar (Tauri) claims "Instant startup — the Rust backend initializes in milliseconds" and publishes a benchmark harness against Raycast. The README table on 2026-10-13 showed "n/a" for its latency rows ([README](https://github.com/Xoshbin/asyar)).
- Loungy chose GPUI (Rust, GPU-accelerated) ([README](https://github.com/MatthiasGrandl/Loungy)). Wox moved to an in-house Go GPU UI ([AGENTS.md](https://github.com/Wox-launcher/Wox/blob/master/AGENTS.md)).

**ML integration examples:**
- Native: Tinycast runs Core ML models in-process for dictation ([QwenRecognizer.swift](https://github.com/abue-ammar/tinycast/blob/main/Tinycast/Features/Dictation/Helper/QwenRecognizer.swift)). Sidekick embeds a llama.cpp server with a watchdog entitlement file (`llama-server-watchdog.entitlements`) and uses similarity-search-kit ([Sidekick repo](https://github.com/johnbean393/Sidekick)).
- Tauri: vecDir uses Tauri, Rust and SQLite with embeddings from an OpenAI-compatible local server ([vecDir](https://github.com/alpaim/vecDir)).

### Inferences
- **Native Swift: best UX fidelity.**
  - You get a true non-activating NSPanel, reliable Korean marked-text handling via the AppKit field editor, Liquid Glass via `NSGlassEffectView` and SwiftUI `.glassEffect`, and the smallest memory overhead.
  - Embedding inference can use Core ML or MLX Swift in-process, or a bundled llama.cpp or other runtime as a helper process (as Sidekick does).
  - Cost: Swift-only UI work, and the app is macOS-only.
- **Tauri 2 + tauri-nspanel: workable.**
  - The Rust backend can host ONNX, candle or llama.cpp bindings, and the web UI is quick to iterate on.
  - Risks: WKWebView IME edge cases (handle `isComposing` / keyCode 229 carefully), an extra layer between you and NSPanel focus semantics, and the community-maintained panel plugin.
- **Electron: least attractive here.**
  - Its panel focus-stealing history, the documented CJK composition bugs in programmatically shown overlays, and the Chromium footprint all count against it. SuperCmd shows it can be made to work with many workarounds.
- **A hybrid architecture fits all stacks:** a native Swift UI shell plus a separate embedding/indexing service (an XPC helper, a launchd agent registered via SMAppService, or a local HTTP/gRPC daemon). It keeps the panel responsive while indexing, and lets a Raycast-compatible extension reuse the same daemon.

### Gaps
- I found no head-to-head benchmark (hotkey-to-paint latency, RAM) across native, Tauri and Electron launchers on macOS 26/27; Asyar's harness exists but no numbers were published.
- I didn't verify tauri-nspanel's behavior with the Korean IME, or whether WKWebView in a non-activating panel has composition bugs similar to Electron's.

---

## Q7. Distribution: Developer ID + notarization, sandbox/file access, Full Disk Access, launch at login

### Takeaway
Ship outside the Mac App Store as a Developer-ID-signed, hardened-runtime, notarized and stapled app. ⌥Space via Carbon works unsandboxed; the macOS 15.0–15.1 restriction hit sandboxed apps only. If you sandbox anyway, file access must go through user-selected folders persisted as security-scoped bookmarks. Safari history requires Full Disk Access, which the user grants manually because there is no API to request it. Use `SMAppService.mainApp` (macOS 13+) for launch at login.

### Cited Findings
- **Apple notarization:**
  - "Beginning in macOS 10.15, all software built after June 1, 2019, and distributed with Developer ID must be notarized." Apps on the Mac App Store are exempt.
  - Requirements: a Developer ID certificate, "Enable the Hardened Runtime capability", and "Include a secure timestamp".
  - "Starting November 1, 2023, the Apple notary service no longer accepts uploads from `altool` or Xcode 13 or earlier" (use `notarytool`).
  - "When you enable the extra security enforced by the hardened runtime… Plug-ins… inherit the entitlements of the host process" ([Apple: Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)).
- **Unsigned builds:** "Because Ueli is neither signed nor notarized, macOS will prevent you from installing or opening the app" ([Ueli README](https://github.com/oliverschwendener/ueli)). Tinycast is "self-signed" and relies on Homebrew clearing the quarantine flag ([Tinycast README](https://github.com/abue-ammar/tinycast)).
- **App Sandbox file access:**
  - Access can be extended to "user-selected documents" and maintained "when your app next runs" with bookmark data that includes the security-scope option: "Foundation creates a URL bookmark with an explicit security scope that your app can store and retrieve to subsequently access the resource".
  - Open and save panels run out of process and extend the sandbox to the selected URLs.
  - Since macOS 14, accessing another app's container triggers a user prompt ([Apple: Accessing files from the macOS App Sandbox](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)).
- **Full Disk Access:**
  - Apple Developer Forums report it is granted only via System Settings: "there is no API the app can use to get that access" ([Apple Developer Forums 687633](https://developer.apple.com/forums/thread/687633)).
  - Reading Safari's original `History.db` (`history_items`, `history_visits`) needs Full Disk Access ([SQLite forum](https://sqlite.org/forum/forumpost/d264a96f01)).
  - The URL-scheme shortcut to open the FDA pane reportedly doesn't work from sandboxed apps ([LiveCode forum](https://forums.livecode.com/viewtopic.php?p=219986)).
- **SMAppService:** "In macOS 13 and later, use `SMAppService` to register and control `LoginItems`, `LaunchAgents`, and `LaunchDaemons` as helper executables for your app" (macOS 13.0+) ([Apple: SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice)).
  - `register()` can succeed while the status stays `requiresApproval`, waiting on the user ([nilcoalescing](https://nilcoalescing.com/blog/LaunchAtLoginSetting); [Apple: mainApp](https://developer.apple.com/documentation/servicemanagement/smappservice/mainapp)).
  - Vicinae uses `SMAppService.mainAppService` for autostart ([macos-login-item.mm](https://github.com/vicinaehq/vicinae/blob/main/src/server/src/services/autostart/macos-login-item.mm)).
  - `sindresorhus/LaunchAtLogin-Modern` (582 stars, MIT, last push 2024-01) wraps this and is used by Sidekick ([repo](https://github.com/sindresorhus/LaunchAtLogin-Modern); [Sidekick deps](https://github.com/johnbean393/Sidekick)).
- **Input Monitoring is sandbox-compatible:** if you later add a CGEventTap, the Input Monitoring privilege "is easily available to sandboxed apps, and even apps published on the Mac App Store" ([Apple Developer Forums 707680](https://developer.apple.com/forums/thread/707680)).

### Inferences
- **Recommended path:** Developer ID, hardened runtime, `notarytool submit --wait`, then `stapler staple`. Distribute a DMG or Homebrew cask (like Sol and Wox) with Sparkle for updates (Sidekick depends on Sparkle).
- **Onboard permissions in stages, not all at first launch:**
  - Folders to index: open panel plus security-scoped bookmarks, even when unsandboxed, for a clean consent model.
  - Optional Full Disk Access for Safari history and Mail.
  - Optional Accessibility, only if you add paste-into-frontmost-app or a CGEventTap.
- **Run indexing as a separate process.** An `SMAppService` LaunchAgent can keep the embedding index fresh while the UI app is not running.

### Gaps
- I didn't confirm whether macOS 26 or 27 changed Full Disk Access semantics or Safari's history storage location.
- I found no Apple documentation on whether TCC prompts apply to a launcher reading `~/Library/Safari` through bookmarks.
