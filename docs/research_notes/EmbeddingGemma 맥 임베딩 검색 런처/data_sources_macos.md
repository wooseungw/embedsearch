# Data sources for a native macOS semantic search launcher: collection, change detection, permissions, privacy

Research date: 2026-10-13. Target: native macOS app (Swift), Apple Silicon, fully local/offline, Korean + English content, macOS 15 Sequoia / macOS 26 Tahoe.

**How claims were verified.** Many claims below were checked directly on a Mac running **macOS 26.6.2 (build 25G83)** with the **MacOSX26.5 SDK** headers (Command Line Tools). These are marked **[Local verification]**, and each one gives the file or command used plus the matching Apple documentation URL where one exists. The shell reported `x86_64` from `uname -m`, so it was either an Intel Mac or a Rosetta shell. OS-level behavior such as file paths, Settings extensions and Spotlight should be the same on Apple Silicon. Vision results should be re-checked on Apple Silicon. Personal file names, URLs and shortcut names seen during verification were deliberately left out.

---

## Q1. Local documents/files: enumeration, Spotlight vs own crawler, FSEvents, text extraction, OCR (Korean), sandbox access, skip rules

### Takeaway
Build your own crawler over folders the user picks, use FSEvents to keep it current, and extract text with Apple's own frameworks:
- **Change detection:** FSEvents with a persisted event ID and device UUID, so the app can catch up after a relaunch.
- **Text extraction:** PDFKit for PDF; NSAttributedString or `textutil` for RTF/DOC/DOCX/ODT/HTML/WebArchive; ZIP+XML parsing for PPTX/XLSX.
- **OCR:** Vision, which **does support Korean (`ko-KR`) in `.accurate` mode only**.
- **Spotlight:** useful for *finding* candidate files and for querying text content, but you **cannot read back `kMDItemTextContent`** through `mdls` or MDItem. The undocumented `mdimport -t -d3` debug path can dump the importer's extracted text, but it is a CLI debugging tool and not a production API.

### Cited Findings

**Spotlight metadata (NSMetadataQuery / MDQuery / mdfind)**
- `kMDItemTextContent` comes back as `(null)` from `mdls` on an indexed PDF. A content query such as `mdfind -onlyin ~/Workspace -count 'kMDItemTextContent == "*research*"cd'` still matches hundreds of files. So Spotlight's text index can be *queried* but its contents cannot be *retrieved* as an attribute. — [Local verification: `mdls -name kMDItemTextContent <pdf>` → `(null)`; `mdfind ... kMDItemTextContent` → 777 hits]
- Eclectic Light (Howard Oakley, 2026) says the same thing: `mdls` output covers Spotlight's index entries "except for indexed text content. The only way to assess that is by searching for text it should contain". By contrast, `mdimport` output shows the text the importer extracted. — [Eclectic Light: How to check whether Spotlight is getting the right metadata (2026-05-08)](https://eclecticlight.co/2026/05/08/how-to-check-whether-spotlight-is-getting-the-right-metadata/)
- `mdimport -t -d3 <file>` runs the system Spotlight importer in test mode and prints `kMDItemTextContent`. It does not write to the index; per `man mdimport`, `-t` means "Request Spotlight to test import file". This worked for a **.pptx with Korean text** and for a **.docx**. The text is printed with `\Uxxxx` escapes, so it must be decoded. — [Local verification: `mdimport -t -d3` on pptx/docx; `man mdimport`]
- macOS 26.6.2 ships system importers in `/System/Library/Spotlight/`: Application, Archives, Audio, Automator, CoreMedia, Font, iCal, Image, iPhoto, iWork, Mail, MIDI, **Office**, **PDF**, PS, **RichText** and vCard `.mdimporter` bundles. So Office (docx/pptx/xlsx) and iWork text extraction is built in, but only through Spotlight. — [Local verification: `ls /System/Library/Spotlight/`]
- Spotlight has known indexing blind spots. Plain-text files that start with certain leading characters are not content-indexed, because macOS trusts the file's leading "magic" bytes over its UTI. JSON documents are another 2026-reported blind spot. — [Eclectic Light (2026-05-08)](https://eclecticlight.co/2026/05/08/how-to-check-whether-spotlight-is-getting-the-right-metadata/); [Eclectic Light: Spotlight's blind spot: JSON documents (2026-07-15)](https://eclecticlight.co/2026/07/15/spotlights-blind-spot-json-documents/)
- `NSMetadataQuery` supports live updates through `enableUpdates`, `NSMetadataQueryDidFinishGatheringNotification`, `NSMetadataQueryDidUpdateNotification` and `NSMetadataQueryUpdateAddedItemsKey` (and the matching removed/changed keys). This can serve as a change feed for *metadata-level* changes. — [Local verification: SDK `Foundation.framework/Headers/NSMetadata.h` lines 54, 87–91]; [Apple: NSMetadataQuery](https://developer.apple.com/documentation/foundation/nsmetadataquery)
- **Core Spotlight semantic search** (WWDC24) only covers content the app *donates* to its own private, entirely local index. Other apps cannot see that data, and it does not index arbitrary user files. — [WWDC24 session 10131 "Support semantic search with Core Spotlight"](https://developer.apple.com/videos/play/wwdc2024/10131/)
- One developer reported in April 2026 that Core Spotlight semantic search returned the same results as lexical search on iOS 26 beta, with an embedding-timeout error logged under `CSUserQuery`. That is one report, not an Apple statement. — [Apple Developer Forums profile post (shinhong_park)](https://origin-devforums.apple.com/forums/profile/shinhong_park)

**FSEvents for incremental re-indexing** (all from the SDK header `CoreServices.framework/Frameworks/FSEvents.framework/Headers/FSEvents.h`)
- **Resuming after relaunch:** FSEvents keeps events "in a persistent, per-volume database". A client can store the last event ID together with the device UUID from `FSEventsCopyUUIDForDevice()`, then later pass that ID as `sinceWhen` to `FSEventStreamCreateRelativeToDevice()` "as long as its UUID matches what you stored". This is how an indexer catches up on changes made while it was not running. — [Local verification: FSEvents.h lines ~128–136]; [Apple: File System Events](https://developer.apple.com/documentation/coreservices/file_system_events)
- **Flags that matter:**
  - `kFSEventStreamCreateFlagFileEvents` gives per-file events; the default is directory-level granularity.
  - `kFSEventStreamEventFlagMustScanSubDirs (0x1)` means events were coalesced or dropped, so the subtree must be rescanned.
  - `kFSEventStreamEventFlagEventIdsWrapped (0x8)` means stored IDs are invalid and a full rescan is needed.
  - `kFSEventStreamEventFlagHistoryDone (0x10)` marks the end of the replayed history.
  - `kFSEventStreamCreateFlagFullHistory` is available from macOS 10.15.
  - [Local verification: FSEvents.h lines 308, 398, 422, 435]
- `FSEventStreamScheduleWithRunLoop` is **deprecated since macOS 13** ("Use FSEventStreamSetDispatchQueue instead."). — [Local verification: FSEvents.h line 1162]
- The archived File System Events Programming Guide covers the conceptual model. — [Apple archive: FSEvents Programming Guide](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/Introduction/Introduction.html)

**Text extraction**
- **PDF:** PDFKit exposes `PDFDocument.string` and per-page `PDFPage.string` / `PDFPage.attributedString`. — [Local verification: SDK `PDFKit.framework/Headers/PDFDocument.h:193`, `PDFPage.h:137–138`]; [Apple: PDFDocument](https://developer.apple.com/documentation/pdfkit/pdfdocument)
- **Word-family documents:** NSAttributedString reads the document types `NSRTFDTextDocumentType`, `NSHTMLTextDocumentType`, `NSDocFormatTextDocumentType` (.doc), `NSWordMLTextDocumentType`, `NSWebArchiveTextDocumentType`, `NSOfficeOpenXMLTextDocumentType` (.docx, macOS 10.5+) and `NSOpenDocumentTextDocumentType` (.odt, macOS 10.5+). — [Local verification: SDK `AppKit.framework/Headers/NSAttributedString.h` lines 117–118, 265–269]
- **textutil:** the CLI wraps the same Cocoa text system and converts between `txt, html, rtf, rtfd, doc, docx, wordml, odt, or webarchive`. — [Local verification: `man textutil`]
- **PPTX/XLSX:** AppKit has no native reader for these. Your options are to parse the ZIP+XML yourself (for example with ZIPFoundation, MIT, ★2.7k, active 2026-09), use CoreXLSX (Apache-2.0, ★907, last push 2024-03), or use the Spotlight Office importer via `mdimport` as described above. — [GitHub: weichsel/ZIPFoundation](https://github.com/weichsel/ZIPFoundation); [GitHub: CoreOffice/CoreXLSX](https://github.com/CoreOffice/CoreXLSX); repo stats from `gh repo view` on 2026-10-13

**OCR (Vision) – Korean support**
- On macOS 26.6.2, `VNRecognizeTextRequest` is at **revision 3**. In `.accurate` mode it supports 30 languages, **including `ko-KR`**: en-US, fr-FR, it-IT, de-DE, es-ES, pt-BR, zh-Hans, zh-Hant, yue-Hans, yue-Hant, **ko-KR**, ja-JP, ru-RU, uk-UA, th-TH, vi-VT, ar-SA, ars-SA, tr-TR, id-ID, cs-CZ, da-DK, nl-NL, no-NO, nn-NO, nb-NO, ms-MY, pl-PL, ro-RO and sv-SE. **`.fast` mode supports only en/fr/it/de/es/pt.** Korean OCR therefore needs `.accurate`. — [Local verification: compiled Swift probe calling `supportedRecognitionLanguages()`]; [Apple: VNRecognizeTextRequest](https://developer.apple.com/documentation/vision/vnrecognizetextrequest)
- An older Apple Developer Forums answer says Revision 2 did **not** include Korean; it listed only English, Chinese, Portuguese, French, Italian, German and Spanish. Korean support therefore depends on the revision, and that answer is now outdated. — [Apple Developer Forums thread 121048](https://developer.apple.com/forums/thread/121048)
- The Swift-native `RecognizeTextRequest` (macOS 15+) reports the same 30 languages, including `ko-Kore-KR`. — [Local verification]; [Apple: RecognizeTextRequest](https://developer.apple.com/documentation/vision/recognizetextrequest)
- **macOS 26 addition:** `RecognizeDocumentsRequest` (macOS 26.0+) reads document *structure*: paragraphs, tables, lists and similar. It reports the same 30 languages, including `ko-Kore-KR`. — [Local verification]; [Apple: RecognizeDocumentsRequest](https://developer.apple.com/documentation/vision/recognizedocumentsrequest); [WWDC25 session 272 "Read documents using the Vision framework"](https://developer.apple.com/videos/play/wwdc2025/272/)
- Maccy, an open-source clipboard manager, already OCRs image clipboard items with `VNRecognizeTextRequest` at `recognitionLevel = .accurate`, so copied screenshots become searchable. — [GitHub: p0deje/Maccy `Maccy/Models/HistoryItem.swift` (lines ~247–253)](https://github.com/p0deje/Maccy/blob/master/Maccy/Models/HistoryItem.swift)

**Sandboxed access to user-chosen folders (security-scoped bookmarks)**
- Foundation provides:
  - `NSURLBookmarkCreationWithSecurityScope` and `NSURLBookmarkCreationSecurityScopeAllowOnlyReadAccess` when creating a bookmark.
  - `NSURLBookmarkResolutionWithSecurityScope` when resolving it.
  - `startAccessingSecurityScopedResource` / `stopAccessingSecurityScopedResource`. "Each call to startAccessingSecurityScopedResource that returns YES must be balanced" with a stop call.
  - `NSURLBookmarkResolutionWithoutImplicitStartAccessing` (macOS 11.2+).
  - [Local verification: SDK `Foundation.framework/Headers/NSURL.h` lines 428–437, 469–473]
- Apple's guide covers persistent access to folders the user picked in an open panel. It uses the `com.apple.security.files.user-selected.read-only` (or read-write) entitlement and the `com.apple.security.files.bookmarks.app-scope` entitlement, and it requires the bookmark to be re-created when it resolves as stale. — [Apple: Accessing files from the macOS App Sandbox](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox). The page is JS-rendered and its body could not be fetched; the entitlement names are standard, but check the exact wording on the page.

### Inferences
- **Recommended pipeline.** The user picks root folders; persist them as security-scoped bookmarks (needed if sandboxed, harmless otherwise). Then:
  1. Do an initial crawl with `FileManager.enumerator(at:includingPropertiesForKeys:[.contentModificationDateKey,.fileSizeKey,.isDirectoryKey,.contentTypeKey], options:[.skipsHiddenFiles,.skipsPackageDescendants])`.
  2. Store `(path, inode/fileResourceIdentifier, mtime, size, content hash)` per document.
  3. Start a file-level FSEvents stream with `sinceWhen = lastEventId`, keyed by device UUID.
  4. On `MustScanSubDirs`, `EventIdsWrapped` or a UUID mismatch, fall back to an mtime/size diff rescan.
- **Skip rules** (design choice, not from a source):
  - Exclude `.git`, `node_modules`, `.venv`, `__pycache__`, `build`/`DerivedData`, `.Trash`, package contents (`.app`, `.photoslibrary`) and cloud placeholder files that are not downloaded (`ubiquitousItemDownloadingStatus`).
  - Cap per-file size (for example skip text files above about 10–20 MB) and cap extracted characters per file (Maccy similarly limits text to 1k characters for performance, per a comment at HistoryItem.swift line ~109).
  - Honor `.gitignore` optionally.
- **Mixing Spotlight with your own crawler.** You can use `mdfind`/`NSMetadataQuery` as a fast pre-filter, for example to list PDFs or to find files whose content matches lexical terms for hybrid search. Text for embedding still has to come from your own extractor, because Spotlight will not hand it back.
- **OCR cost.** OCR is expensive, so run it lazily: only on PDFs where `PDFPage.string` is empty or near-empty (scanned PDFs), and on images in folders the user opted into. Use `.accurate` with `recognitionLanguages = ["ko-KR","en-US"]` and `automaticallyDetectsLanguage`.

### Gaps
- Whether `mdimport -t -d3` output is stable, allowed in a sandboxed app (it spawns a process, so probably not) or acceptable to App Review. It is a debugging interface, and no official documentation endorses it for text extraction.
- No Apple API found for reading Spotlight's extracted text back for arbitrary files. Some macOS 27 coverage mentions a rebuilt Spotlight with LLM-oriented developer hooks ("SpotlightSearchTool"), but it comes from a single secondary news article ([letsdatascience.com](https://letsdatascience.com/news/apple-rebuilds-search-infrastructure-powering-spotlight-and-b37590b7)) and is not verified against Apple documentation.
- `kFSEventStreamCreateFlagFileEvents` deliveries were not benchmarked under heavy churn, for example `npm install` inside a watched root.

---

## Q2. Clipboard history: changeCount polling, types, macOS 15.4/26 pasteboard privacy, concealed/transient markers, open-source storage

### Takeaway
- **No change-notification API exists.** Every open-source manager polls `NSPasteboard.general.changeCount`; Maccy polls every 0.5 s by default.
- **macOS 15.4 introduced pasteboard privacy:** the `accessBehavior` property, the `detectPatterns`/`detectValues`/`detectMetadata` APIs, and a "Paste from Other Apps" pane in Privacy & Security. Programmatic reads of the general pasteboard can trigger an alert unless the user sets the app to "Allow".
- **On macOS 26 the alert appeared to be off by default** unless a developer flag was set. Its status in later releases is unclear from the sources found.
- **Honor the nspasteboard.org markers:** skip Transient and AutoGenerated items, and skip or encrypt Concealed items. Also exclude password-manager apps.

### Cited Findings

**Polling model (Maccy as reference implementation)**
- Maccy starts a `Timer` with interval `Defaults[.clipboardCheckInterval]` (default **0.5 s**). On each tick it compares `pasteboard.changeCount` to the stored value and processes only on change. It records the source app as `NSWorkspace.shared.frontmostApplication?.bundleIdentifier`. — [GitHub: p0deje/Maccy `Maccy/Clipboard.swift`](https://github.com/p0deje/Maccy/blob/master/Maccy/Clipboard.swift); [`Defaults.Keys+Names.swift` line 29](https://github.com/p0deje/Maccy/blob/master/Maccy/Extensions/Defaults.Keys%2BNames.swift)
- Maccy captures the types `.fileURL, .html, .png, .rtf, .string, .tiff`. It hard-ignores `.autoGenerated, .concealed, .transient`, and treats `.appleWebArchive` and the Safari web archive type as unpersistable. Users can add more ignored types (`ignoredPasteboardTypes`), ignored apps (`ignoredApps`, or `ignoreAllAppsExceptListed`) and regexes (`ignoreRegexp`). The default history size is 200. — [GitHub: Maccy Clipboard.swift lines ~15–40](https://github.com/p0deje/Maccy/blob/master/Maccy/Clipboard.swift); [Defaults.Keys+Names.swift lines 34–71](https://github.com/p0deje/Maccy/blob/master/Maccy/Extensions/Defaults.Keys%2BNames.swift)
- Maccy's README says its default ignore list also includes `com.agilebits.onepassword`, `com.typeit4me.clipping`, `de.petermaurer.TransientPasteboardType`, `Pasteboard generator type` and `net.antelle.keeweb`. It recommends sindresorhus/Pasteboard-Viewer for discovering an app's custom types. — [Maccy README (mirror)](https://github.com/weisJ/Maccy); [GitHub: sindresorhus/Pasteboard-Viewer](https://github.com/sindresorhus/Pasteboard-Viewer)
- **Storage:** Maccy (MIT, ★21.9k, pushed 2026-10-12) stores history with **SwiftData** in `URL.applicationSupportDirectory/"Maccy/Storage.sqlite"`, using `ModelContainer(for: HistoryItem.self)` and a separate `HistoryItemContent` model holding per-type data blobs. — [GitHub: Maccy `Maccy/Storage.swift`](https://github.com/p0deje/Maccy/blob/master/Maccy/Storage.swift); [Models/HistoryItem.swift](https://github.com/p0deje/Maccy/blob/master/Maccy/Models/HistoryItem.swift)
- Clipy (MIT, ★8.9k, pushed 2026-10-13) is another open-source reference; its storage layer was not inspected. — [GitHub: Clipy/Clipy](https://github.com/Clipy/Clipy)

**nspasteboard.org marker conventions**
- `org.nspasteboard.TransientType`: "Data marked transient should not be recorded or displayed in a pasteboard history." — [nspasteboard.org](https://nspasteboard.org/)
- `org.nspasteboard.ConcealedType`: confidential (passwords). "If displayed on screen it should be visually obfuscated"; "Avoid recording it to a file, or consider encrypting it." — [nspasteboard.org](https://nspasteboard.org/)
- `org.nspasteboard.AutoGeneratedType`: "probably should not be recorded as part of the pasteboard history". — [nspasteboard.org](https://nspasteboard.org/)
- `org.nspasteboard.source`: holds the bundle ID of the originating app, for display only. — [nspasteboard.org](https://nspasteboard.org/)
- The site also lists proprietary types to treat equivalently: `de.petermaurer.TransientPasteboardType`, `com.typeit4me.clipping` and `Pasteboard generator type` (transient), `com.agilebits.onepassword` (concealed), and `com.apple.is-remote-clipboard` (Handoff/Universal Clipboard). — [nspasteboard.org](https://nspasteboard.org/)

**macOS 15.4 / 26 pasteboard privacy: APIs (primary source = SDK header)**
- `NSPasteboardAccessBehavior` (macOS 15.4+) has four values: `.default`, `.ask`, `.alwaysAllow` and `.alwaysDeny`. Header text:
  - **`.default`:** "The default behavior for the General pasteboard is to ask upon programmatic access. All other pasteboards default to always allow access. If an app has never triggered a pasteboard access alert, its General pasteboard will report `.default` … Once programmatic pasteboard access triggers the first pasteboard access alert, the state automatically changes to `.ask`. At this point the app starts being shown in System Settings, where the user can toggle the behavior between `.ask`, `.alwaysAllow`, and `.alwaysDeny`."
  - **`.ask`:** "access that is both user originated and paste related will always be allowed, and will not result in a notification."
  - [Local verification: SDK `AppKit.framework/Headers/NSPasteboard.h` lines 50–70]; [Apple: NSPasteboard.AccessBehavior.ask](https://developer.apple.com/documentation/appkit/nspasteboard/accessbehavior-swift.enum/ask); [Apple: .alwaysAllow](https://developer.apple.com/documentation/appkit/nspasteboard/accessbehavior-swift.enum/alwaysallow)
- `NSPasteboard.accessBehavior` is a **read-only** property, available in macOS 15.4+. An app cannot grant itself access. — [Local verification: NSPasteboard.h line 170]
- `detectPatternsForPatterns:completionHandler:`, `detectValuesForPatterns:` and `detectMetadataForTypes:` (macOS 15.4+) inspect the first item "without notifying the person using the app". The patterns are `ProbableWebURL`, `ProbableWebSearch`, `Number`, `Link`, `PhoneNumber`, `EmailAddress`, `PostalAddress`, `CalendarEvent`, `ShipmentTrackingNumber`, `FlightNumber` and `MoneyAmount`; the metadata type is `ContentType`. These calls do *not* return full contents, so they cannot replace reading for a history manager. — [Local verification: NSPasteboard.h lines 75–130, 244–320]
- Apple's AppKit release notes say macOS "alerts a person using a device when your app programmatically reads the general pasteboard". A developer preview was enabled with `defaults write <your_app_bundle_id> EnablePasteboardPrivacyDeveloperPreview -bool yes`. — [Michael Tsai blog: Pasteboard Privacy Preview in macOS 15.4](https://mjtsai.com/blog/2025/05/12/pasteboard-privacy-preview-in-macos-15-4/), quoting [Apple AppKit updates](https://developer.apple.com/documentation/updates/appkit#macOS-pasteboard-privacy)

**Status on macOS 26 and later (conflicting or unclear)**
- **Settings pane:** macOS Tahoe 26 has a **"Paste from Other Apps"** section in Privacy & Security with Ask / Allow / Deny per app. It opens with `x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard`, and a later comment gives `x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Pasteboard`. It resets with `tccutil reset Pasteboard`. — [Michael Tsai blog comments](https://mjtsai.com/blog/2025/05/12/pasteboard-privacy-preview-in-macos-15-4/)
- **Default on macOS 26:** Felix Schwarz commented that "unless you turn it on explicitly via defaults – it seems absent in the macOS 26". — [Michael Tsai blog comments](https://mjtsai.com/blog/2025/05/12/pasteboard-privacy-preview-in-macos-15-4/)
- **Developer flag removed later:** Léo Natan commented that "As per 27.2 beta 2 release notes, EnablePasteboardPrivacyDeveloperPreview is deprecated and no longer offers any functionality." This is a blog comment and was not checked against Apple's release notes. "27.2" may be a typo for 26.2. A separate GitHub issue (October 2026) also says the "developer-preview default was removed" and lists as *open questions* whether the alert is on by default after 27.2 and whether `changeCount`/`types` reads trigger it. — [Michael Tsai blog comments](https://mjtsai.com/blog/2025/05/12/pasteboard-privacy-preview-in-macos-15-4/); [GitHub admax12959/OneShot issue #15](https://github.com/admax12959/OneShot/issues/15)
- **Real-world behavior with the preview on:** one developer's clipboard monitor (ClipBar) showed an alert on *every* pasteboard change unless "Allow" was set in Settings. The alert's own "Allow" applies only once, while the Settings "Allow" is permanent. The developer added a launch-time check that sends users to Settings. Apple told a Feedback filer that the dialog "should NOT include a direct link to the System Settings pane". — [Michael Tsai blog + comments](https://mjtsai.com/blog/2025/05/12/pasteboard-privacy-preview-in-macos-15-4/); [feedback-assistant/reports #655](https://github.com/feedback-assistant/reports/issues/655)
- **Workarounds:** Jeff Johnson (lapcat) chose to "make the app a little worse to avoid the much worse permission prompt". — [lapcatsoftware.com (2025-05-03)](https://lapcatsoftware.com/articles/2025/5/3.html)
- **Built-in competitor:** macOS 26 Spotlight has its own clipboard history. It is off by default, opened with ⌘4 inside Spotlight, enabled in System Settings › Spotlight ("Results from Clipboard" / "Clipboard Search"), and per third-party guides keeps items for 30 min, 8 h or 7 days, with options expanded in 26.1; the retention details conflict between sources. It reportedly does *not* ask for pasteboard permission. — [AppleInsider](https://appleinsider.com/inside/macos-tahoe/tips/spotlight-got-a-huge-upgrade-in-macos-tahoe-heres-how-to-use-it); [Paste blog on Tahoe clipboard history](https://pasteapp.io/blog/macos-tahoe-clipboard-history); [ntiva support article](https://support.ntiva.com/hc/en-us/articles/39853826658701-macOS-Tahoe-Disable-Clipboard-History-in-Spotlight); [Michael Tsai blog comment citing Guilherme Rambo](https://mjtsai.com/blog/2025/05/12/pasteboard-privacy-preview-in-macos-15-4/)

### Inferences
- **Clipboard ingestion design:**
  1. Poll `changeCount` every 0.5–1 s on a background timer.
  2. On change, check `types` first and drop anything carrying Transient, AutoGenerated or Concealed markers, plus the proprietary equivalents.
  3. Drop items whose frontmost or source app is on an exclusion list. Defaults: 1Password, Bitwarden, KeePassXC, Keychain Access, Passwords.app.
  4. Then read `.string`, `.rtf`/`.html` (convert to plain text), `.fileURL` (index the file path and optionally the file) and `.png`/`.tiff` (OCR via Vision `.accurate` with ko+en).
- **Plan for enforcement.** Assume the pasteboard alert can be enforced on some macOS versions. At launch, check `NSPasteboard.general.accessBehavior`. If it is `.ask` or `.alwaysDeny`, show onboarding that explains how to set "Allow" under Privacy & Security › Paste from Other Apps. Apple says the alert itself won't link there, but your app's own onboarding can open the `Privacy_Pasteboard` deep link.
- **Whether `changeCount`/`types` reads trigger the alert is unverified.** The header implies the alert concerns *reading contents*, and the detect APIs exist precisely to avoid reading. Test on a real signed `.app` on each target OS.

### Gaps
- Whether the pasteboard alert is on by default in shipping macOS 26.x or macOS 27.x. Sources conflict, and no Apple release note was retrieved directly.
- Whether polling `changeCount` or `types` alone triggers the alert.
- Clipy's storage format (Realm or another store) was not verified.
- How Apple's built-in Spotlight clipboard history is stored was not established; a MacRumors thread asks but has no authoritative answer: [MacRumors forum](https://forums.macrumors.com/threads/does-anyone-know-how-spotlight-clipboard-history-is-stored-internally.2483728/).

---

## Q3. Browser history & bookmarks: paths, schemas, locks, timestamps, page text, open-source readers

### Takeaway
- **Chromium family:** one SQLite `History` file per profile (`urls` + `visits` tables; timestamps in microseconds since 1601) and one JSON `Bookmarks` file. Readable without TCC by a non-sandboxed app, but the DB is locked while the browser runs, so copy it first.
- **Safari:** `~/Library/Safari/History.db` (seconds since 2001-01-01) and `Bookmarks.plist`, both behind **Full Disk Access**.
- **Firefox:** `places.sqlite` (`moz_places` / `moz_historyvisits` / `moz_bookmarks`; microseconds since 1970).
- **Page text:** browsers mostly do not store page body text. Index title + URL + domain + search terms, plus Chrome `content_annotations` fields and Firefox `moz_places.description` where available. Fetching page content yourself is optional and breaks "fully offline".

### Cited Findings

**Paths (Raycast browser-history extension constants, relative to `~/Library/`)**

| Browser | History path |
|---|---|
| Chrome | `Application Support/Google/Chrome/Default/History` |
| Edge | `Application Support/Microsoft Edge/Default/History` |
| Brave | `Application Support/BraveSoftware/Brave-Browser/Default/History` |
| Vivaldi | `Application Support/Vivaldi/Default/History` |
| Arc | `Application Support/Arc/User Data/Default/History` |
| Opera | `Application Support/com.operasoftware.Opera/History` (no `Default`) |
| Dia | `Application Support/Dia/User Data/Default/History` |
| Helium | `Application Support/Helium/Default/History` |
| Comet | `Application Support/Comet/Default/History` |
| Sidekick | `Application Support/Sidekick/Default/History` |
| Iridium | `Application Support/Iridium/Default/History` |
| Safari | `Safari/History.db` |
| Firefox | `Application Support/Firefox/Profiles/<profile>/places.sqlite` |

Source: [GitHub: raycast/extensions `extensions/browser-history/src/constants.ts`](https://github.com/raycast/extensions/blob/main/extensions/browser-history/src/constants.ts) and [util/index.ts](https://github.com/raycast/extensions/blob/main/extensions/browser-history/src/util/index.ts)

- **Chromium profiles:** profile folders are `Default`, `Profile 1`, and so on. `Local State` (JSON) holds `profile.info_cache`, which maps each profile directory to its metadata (fields include `gaia_name`, `gaia_given_name`, `avatar_icon`, `active_time`, `is_ephemeral`), plus `profiles_order` and `last_used`. Use it to enumerate profiles and label them. — [Local verification: Chrome `Local State` keys]

**Chromium `History` schema (Chrome on this machine, 2026-10)**
- Tables: `urls`, `visits`, `keyword_search_terms`, `content_annotations`, `context_annotations`, `clusters`, `clusters_and_visits`, `cluster_keywords`, `journeys`, `downloads`, `segments`, `visited_links`, `meta` and others. — [Local verification: `sqlite3 "file:.../History?immutable=1" .tables`]
- `urls(id, url, title, visit_count, typed_count, last_visit_time, hidden)`. — [Local verification]
- `visits(id, url → urls.id, visit_time, from_visit, external_referrer_url, transition, segment_id, visit_duration, …, opener_visit, app_id)`. — [Local verification]
- `keyword_search_terms(keyword_id, url_id, term, normalized_term)`, which holds the omnibox search queries users typed. This is a high-value text field for natural-language matching. — [Local verification]
- `content_annotations(visit_id, …, categories, entities, related_searches, search_normalized_url, search_terms, alternative_title, page_language, password_state, has_url_keyed_image)`. These are Chrome-computed annotations, not page text. — [Local verification]
- Chrome's `History` uses **rollback-journal mode** (`PRAGMA journal_mode` returns `delete`; a `History-journal` file sits beside it), not WAL. — [Local verification]
- **Timestamps:** Chromium uses microseconds since 1601-01-01 UTC. Unix seconds = `t/1_000_000 − 11644473600`; in SQLite, `datetime(last_visit_time/1000000-11644473600,'unixepoch','localtime')`. — [Timothy Comeau: Chrome History](https://timothycomeau.com/writing/chrome-history); [Forensic Focus forum](https://www.forensicfocus.com/forums/general/browser-history-time-stamp-question/)
- **Bookmarks:** the `Bookmarks` JSON has `{checksum, roots:{bookmark_bar, other, synced}}`. Nodes have `type` (`url`/`folder`), `name`, `url`, `guid`, `children`, and `date_added`/`date_last_used` as strings in the same 1601-epoch microseconds. A file named `EncryptedBookmarks2` was also present in the current Chrome profile; its purpose is unknown. — [Local verification: Chrome `Default/Bookmarks` structure, values redacted]

**Safari**
- `~/Library/Safari/` returns **"Operation not permitted"** to a process without Full Disk Access. — [Local verification: `ls ~/Library/Safari/`]
- **History tables:** `History.db` has `history_items` (one row per URL: `id, url, visit_count, …`) and `history_visits` (one row per visit: `history_item → history_items.id`, `visit_time` REAL, `title`, `load_successful`, redirect fields). — [Plaso Safari parser](https://plaso-fork.readthedocs.io/en/latest/_modules/plaso/parsers/sqlite_plugins/safari.html); [Autopsy ExtractSafari source](https://sleuthkit.org/autopsy/docs/api-docs/4.19.1/_extract_safari_8java_source.html)
- **Timestamps:** Safari stores seconds since 2001-01-01 (Core Data / NSDate epoch). Raycast's Safari extension queries `datetime(visit_time+978307200,'unixepoch','localtime')` joining `history_items` and `history_visits`, grouping by URL, ordering by `visit_time DESC`, and uses `useSQL(... permissionPriming: "This is required to search your Safari history.")`. — [GitHub: raycast/extensions `extensions/safari/src/hooks/useHistorySearch.ts`](https://github.com/raycast/extensions/blob/main/extensions/safari/src/hooks/useHistorySearch.ts)
- **Bookmarks:** `Bookmarks.plist` is a binary plist. Folders have `WebBookmarkType` = List with a `Children` array; leaves (`WebBookmarkTypeLeaf`) carry `URLString`, with the title at `URIDictionary.title`. The Reading List is a top-level child titled `com.apple.ReadingList`. — [Chromium Safari importer](https://chromium.googlesource.com/git/chromium/+/trunk/chrome/browser/importer/safari_importer.mm); [alexwlchan: export URLs from Safari Reading List](https://alexwlchan.net/2015/export-urls-from-safari-reading-list/); [Firefox SafariProfileMigrator](https://arai.searchfox.org/firefox-main/source/browser/components/migration/SafariProfileMigrator.sys.mjs)
- **Profiles:** Safari 17+ supports profiles, each with separate history, cookies, website data, extensions, Tab Groups and favorites. — [Apple Support: Use profiles in Safari on Mac](https://support.apple.com/en-au/105100)

**Firefox**
- Current schema columns (from the `nsPlacesTables.h` CREATE TABLE definitions):
  - `moz_places(id, url, title, rev_host, visit_count, hidden, typed, frecency, last_visit_date, guid, foreign_count, url_hash, description, preview_image_url, site_name, origin_id, recalc_frecency, alt_frecency, recalc_alt_frecency)`
  - `moz_historyvisits(id, from_visit, place_id, visit_date, visit_type, session, source, triggeringPlaceId)`
  - `moz_bookmarks(id, type, fk → moz_places.id, parent, position, title, keyword_id, folder_type, dateAdded, lastModified, guid, syncStatus, syncChangeCounter)`
  - [Searchfox: toolkit/components/places/nsPlacesTables.h](https://searchfox.org/mozilla-central/source/toolkit/components/places/nsPlacesTables.h)
- Timestamps are PRTime, microseconds since the Unix epoch: `datetime(visit_date/1000000,'unixepoch')`. — [Plaso Firefox history parser](https://plaso.readthedocs.io/en/latest/_modules/plaso/parsers/sqlite_plugins/firefox_history.html); [forensics.wiki: Mozilla Firefox 3 history file format](https://forensics.wiki/mozilla_firefox_3_history_file_format)

**Locks and safe reading**
- **`immutable=1`:** SQLite's `immutable=1` "skips all file locking and change detection". "If … a database file is immutable and that file changes anyhow, then SQLite might return incorrect query results and/or SQLITE_CORRUPT errors." — [SQLite: URI filenames](https://www.sqlite.org/uri.html)
- **`mode=ro`:** opens read-only but keeps normal locking and change detection. — [SQLite: URI filenames](https://www.sqlite.org/uri.html)
- **Raycast's approach:** `@raycast/utils` (`useSQL` / `executeSQL`) first tries the DB directly through `node:sqlite`, falling back to `sqlite3 --json --readonly`. On SQLite error 5 (BUSY) or 14 (CANTOPEN) it **copies the DB to `$TMPDIR/useSQL/<hash>/db.db` and writes empty `-shm`/`-wal` files** beside the copy. An `EPERM` on copy becomes a PermissionError, and the UI then sends the user to `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`. — [GitHub: raycast/utils `src/sql-utils.ts`](https://github.com/raycast/utils/blob/main/src/sql-utils.ts); [raycast/utils `src/useSQL.tsx`](https://github.com/raycast/utils/blob/main/src/useSQL.tsx); [Raycast docs: useSQL](https://developers.raycast.com/utilities/react-hooks/usesql)

**Does any browser store page text locally?**
- Chrome's optional AI history search ("history embeddings") splits visited pages into passages and stores encrypted, compressed passage embeddings locally in Chrome's history storage, according to a third-party technical analysis. Chromium has a `components/history_embeddings` component, for example with a `passage_extraction_delay` default of 5000 ms. — [dejan.ai: Inside Chrome's semantic engine](https://dejan.ai/blog/inside-chromes-semantic-engine-a-technical-analysis-of-history-embeddings/); [Chromium history_embeddings_features.h](https://chromium.googlesource.com/chromium/src/+/798e59c5275d4131797e8ea2e96e6c6000256b58/components/history_embeddings/history_embeddings_features.h)
- No history-embeddings database file was present in the Chrome profile on the test machine, where the feature is likely off or unavailable in the region. — [Local verification: no `*embed*`/`*passage*` files in `Default/`]
- Firefox `moz_places` has `description`, `site_name` and `preview_image_url` columns (page metadata). — [Searchfox nsPlacesTables.h](https://searchfox.org/mozilla-central/source/toolkit/components/places/nsPlacesTables.h)

**Open-source readers**

| Repo | License | Stars | Last push | Covers |
|---|---|---|---|---|
| [raycast/extensions](https://github.com/raycast/extensions) (`browser-history`, `safari`, bookmarks extensions) | MIT | ★7.8k | 2026-10 | History, bookmarks |
| [browser-history/browser-history](https://github.com/browser-history/browser-history) (Python) | Apache-2.0 | ★221 | 2025-12 | History |
| [RyanDFIR/hindsight](https://github.com/RyanDFIR/hindsight) (Chrome/Chromium/Firefox forensics; formerly obsidianforensics) | Apache-2.0 | ★1.5k | 2026-10 | Forensics |
| [Plaso](https://plaso.readthedocs.io/en/latest/_modules/plaso/parsers/sqlite_plugins/firefox_history.html) and [Autopsy](https://sleuthkit.org/autopsy/docs/api-docs/4.19.1/_extract_safari_8java_source.html) | — | — | — | Forensic parsers |

Repo stats are from `gh repo view` on 2026-10-13.

### Inferences
- **Ingest pattern (per browser and profile):**
  1. Detect installed browsers by checking for their data directories.
  2. Enumerate profiles (Chromium `Local State`, Firefox `profiles.ini`).
  3. Copy `History` (+ `-journal`/`-wal` if present) to an app-private temp dir. Open the copy read-only rather than relying on `immutable=1` against a live file.
  4. Query incrementally with `WHERE last_visit_time > :checkpoint` (Chromium) / `last_visit_date > :checkpoint` (Firefox) / `visit_time > :checkpoint` (Safari).
  5. Re-copy when the source file's mtime changes, using FSEvents on the profile folder or periodic polling.
- **Embed one document per URL, not per visit.** Example: `"{title} — {domain} — {url path tokens} — searched: {search terms}"`. Store visit_count and last_visit for ranking and recency boosts.
- **Chrome `keyword_search_terms`** carries natural-language queries, often Korean, which makes it especially useful for embedding-based matching.
- **Fetching page content** for richer embeddings breaks "fully offline" and leaks browsing to the network again. Offer it as an explicit opt-in and limit it to bookmarks.

### Gaps
- Safari 17+ per-profile storage path for `History.db`/bookmarks (inside `~/Library/Safari/Profiles/<UUID>/` or the Safari container?). Not verified; no source found and the local machine lacked FDA.
- Arc's bookmark/sidebar storage file (commonly cited as `StorableSidebar.json`) was **not** found at the top level of `~/Library/Application Support/Arc/` on the test machine. Unverified.
- The exact storage location and format of Chrome's history-embedding passages comes only from a third-party analysis. The Chromium source file could not be fetched.
- Whether Firefox holds an exclusive lock on `places.sqlite` while running was not verified; the copy-first strategy covers either case.

---

## Q4. Installed apps, System Settings panes, commands/actions, and bilingual (Korean/English) descriptions

### Takeaway
- **Apps:** enumerate with a Spotlight query (`kMDItemContentType == "com.apple.application-bundle"`) or by scanning `/Applications`, `~/Applications`, `/System/Applications` (+`Utilities`), then resolve with `NSWorkspace`. Spotlight already gives **localized + English names** (`kMDItemDisplayName` = "계산기.app", `kMDItemAlternateNames` = "Calculator.app").
- **System Settings (macOS 13+):** panes are ExtensionKit extensions in `/System/Library/ExtensionKit/Extensions/`. Each ships a localized **`.searchTerms`** plist mapping deep-link anchors (for example `Privacy_AllFiles`) to localized titles and keyword lists in Korean and English. That is a ready-made bilingual corpus for embedding.
- **Commands:** the `shortcuts list/run` CLI, plus AppleScript/shell script commands in the Raycast style.

### Cited Findings

**Installed apps**
- `mdfind 'kMDItemContentType == "com.apple.application-bundle"'` returned **440** app bundles on the test machine. — [Local verification]
- `mdls` on `/System/Applications/Calculator.app` gives `kMDItemDisplayName = "계산기.app"` (system language Korean), `kMDItemAlternateNames = ("Calculator.app")` and `kMDItemCFBundleIdentifier = "com.apple.calculator"`. — [Local verification]
- On macOS 26, system apps carry localized names in `Contents/Resources/InfoPlist.loctable`, a plist keyed by language. For Calculator, `ko` → `CFBundleDisplayName = "계산기"`. — [Local verification: `plutil -convert json InfoPlist.loctable`]
- `LSCopyApplicationURLsForBundleIdentifier` is deprecated in the SDK ("Use -[NSWorkspace URLsForApplicationsWithBundleIdentifier:] instead."). The replacement `-[NSWorkspace URLsForApplicationsWithBundleIdentifier:]` is available from macOS 12. Also present: `URLForApplicationWithBundleIdentifier:` (macOS 10.6+), `URLsForApplicationsToOpenURL:` (macOS 12+) and `iconForFile:`. `iconForFileType:` is deprecated in favor of `iconForContentType:`. — [Local verification: SDK `LaunchServices.framework/Headers/LSInfo.h:162`, `AppKit.framework/Headers/NSWorkspace.h` lines 66–123, 456]; [Apple: NSWorkspace](https://developer.apple.com/documentation/appkit/nsworkspace)
- For install/uninstall detection, `NSMetadataQuery` live updates (see Q1) or FSEvents on the application folders both work. — [Local verification: NSMetadata.h]; [Apple: NSMetadataQuery](https://developer.apple.com/documentation/foundation/nsmetadataquery)

**System Settings panes (macOS 13+ / 26)**
- On macOS 26.6.2, **51** extensions in `/System/Library/ExtensionKit/Extensions/` declare `EXExtensionPointIdentifier = com.apple.Settings.extension.ui` (out of 242 `.appex` there). Examples: `com.apple.BluetoothSettings`, `com.apple.wifi-settings-extension`, `com.apple.settings.PrivacySecurity.extension`, `com.apple.Appearance-Settings.extension`, `com.apple.Keyboard-Settings.extension`, `com.apple.Displays-Settings.extension`, `com.apple.Battery-Settings.extension`, `com.apple.Spotlight-Settings.extension`, `com.apple.Siri-Settings.extension` and `com.apple.Lock-Screen-Settings.extension`. — [Local verification: PlistBuddy over each `Info.plist`]
- Each Settings extension's `Info.plist` has `EXAppExtensionAttributes.SettingsExtensionAttributes` with these keys:
  - `legacyBundleIdentifier` (for example `com.apple.preferences.Bluetooth`)
  - `legacyPrefPaneBundleName` (for example `Bluetooth.prefPane`)
  - `allowsXAppleSystemPreferencesURLScheme = true`
  - `searchTermsFileName`
  - [Local verification: Bluetooth.appex Info.plist]
- **Localized search-terms files:** each extension's `Resources/<lang>.lproj/<searchTermsFileName>.searchTerms` is a plist. Its top-level keys are **anchors**; each value holds `localizableStrings: [{title, index}]`, where `index` is a comma-separated keyword list. There are 47 such English files with **563 anchors** in total.
  - **PrivacySecurity anchors:** `Privacy_AllFiles`, `Privacy_Accessibility`, `Privacy_Automation`, `Privacy_ScreenCapture`, `Privacy_ListenEvent`, `Privacy_Microphone`, `Privacy_Camera`, `Privacy_LocationServices`, `Privacy_FilesAndFolders`, `Privacy_DevTools`, `Privacy_AppBundles`, `FileVault`, `LockdownMode` and others.
  - **Korean examples:** `Privacy_AllFiles` → title "응용 프로그램이 모든 사용자 파일에 접근하는 것을 허용", index "파일, 전체 디스크 접근 권한, 완료, 전체, 디스크". `LockdownMode` → "차단 모드" with keywords like "사이버 공격, 해킹, 스파이…". Bluetooth → "Bluetooth 기기" with "무선, 페어링, 연결, 헤드폰, …". Appearance → "하이라이트 색상" / "버튼, 메뉴, 윈도우 보기" with keywords like "화면 모드, 틴트".
  - **English example:** Appearance has "Highlight color" with index "selected, text, highlighting, … appearance".
  - [Local verification: `plutil -convert json` of `en.lproj` and `ko.lproj` `.searchTerms`]
- Legacy `.prefPane` bundles still exist in `/System/Library/PreferencePanes/` on macOS 26: Accounts, Appearance, Battery, Bluetooth, Displays, Dock, Keyboard, Network, Security, Sound, Spotlight, Trackpad, UniversalAccessPref and others (40 in total). — [Local verification]
- **Deep links:** both the legacy and new identifier forms are in use.
  - Legacy, used by Raycast utils and PermissionsKit for FDA: `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`. — [raycast/utils useSQL.tsx](https://github.com/raycast/utils/blob/main/src/useSQL.tsx); [MacPaw/PermissionsKit MPFullDiskAccessAuthorizer.m](https://github.com/MacPaw/PermissionsKit)
  - New, reported for Tahoe: `x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Pasteboard`. — [Michael Tsai blog comment](https://mjtsai.com/blog/2025/05/12/pasteboard-privacy-preview-in-macos-15-4/)
- **Community lists:**
  - jaywcjlove/SystemSettings-URLs-macOS (★20, pushed 2026-05) extracts identifiers with `strings` on the System Settings binary. — [GitHub](https://github.com/jaywcjlove/SystemSettings-URLs-macOS)
  - bvanpeski/SystemPreferences (★262, last push 2024-01). — [GitHub](https://github.com/bvanpeski/SystemPreferences)
  - MacMost table, last updated on macOS 15.2 (2024-11-18). — [MacMost](https://macmost.com/?p=34261)
  - An older gist targets macOS 10.15. — [gist](https://gist.github.com/ehjmx)

**Commands / actions**
- **Shortcuts CLI:** `shortcuts run <name-or-identifier> [-i input-path] [-o output-path] [--output-type UTI]`. `shortcuts list` lists the user's shortcuts; `--show-identifiers` appends UUIDs. It exits 0 on success and 1 on error. Apple recommends that shortcuts used from the CLI accept input rather than prompting. — [Local verification: `shortcuts help run`, `shortcuts list --show-identifiers`]; [Apple Shortcuts User Guide: Run shortcuts from the command line](https://support.apple.com/guide/shortcuts-mac/apd455c82f02/mac)
- **Raycast script commands** are shell/AppleScript files with `# @raycast.title`, `@raycast.description`, `@raycast.packageName` and `@raycast.mode` headers. Examples: `commands/system/sleep.applescript` (`tell application "Finder" to sleep`) and `toggle-system-appearance.applescript` (`tell application "System Events" to tell appearance preferences to set dark mode to not dark mode`), plus restart, shutdown, screensaver, empty-trash, restart-dock and restart-finder scripts. — [GitHub: raycast/script-commands `commands/system/`](https://github.com/raycast/script-commands/tree/master/commands/system) (★6.8k, pushed 2026-09)
- **macOS 26 Spotlight actions:** Spotlight runs system and app actions (⌘3), and developers can expose more through **App Intents**. "Quick Keys" are short typed strings (for example "sm") bound to actions. — [AppleInsider: Spotlight in macOS Tahoe](https://appleinsider.com/inside/macos-tahoe/tips/spotlight-got-a-huge-upgrade-in-macos-tahoe-heres-how-to-use-it); [ithinkdiff](https://www.ithinkdiff.com/spotlight-macos-tahoe-quick-keys-clipboard/)
- **Open-source launcher reference:** ospfranco/sol (MIT, ★3.2k, pushed 2026-10) is a macOS launcher and command palette whose code shows app and command indexing. — [GitHub: ospfranco/sol](https://github.com/ospfranco/sol)

### Inferences
- **Bilingual document per app:** combine `kMDItemDisplayName` (localized) + `kMDItemAlternateNames`/`CFBundleName` (English) + `InfoPlist.loctable` `ko`/`en` entries + bundle ID + the app's category (`LSApplicationCategoryType`). Optionally add a hand-curated synonym line for top apps, for example "계산기 Calculator — 계산, 사칙연산, 수식, calculator, math".
- **Bilingual document per Settings anchor:** merge the `en` and `ko` `.searchTerms` title and index for the same anchor key. Build the URL `x-apple.systempreferences:<extension bundle id or legacyBundleIdentifier>?<anchor>`. This gives about 560 well-described deep-linkable items with no hand-writing.
- **Settings format may change.** `.searchTerms` is an undocumented internal format, so parse it defensively and re-scan after OS updates (watch `/System/Library/ExtensionKit/Extensions` mtime or the OS build number).
- **Command corpus:** for built-in actions (sleep, lock, dark mode, empty trash, show desktop, Wi-Fi/Bluetooth toggles), write the Korean and English description pairs yourself. Ingest user Shortcuts by name from `shortcuts list`. Descriptions are not exposed by the CLI, so embed the name only, optionally translated with Apple's on-device Translation framework (present in the macOS 26 SDK; Korean pair availability not verified).
- **Lock screen:** there is no public lock-screen API. Options are `pmset displaysleepnow` (locks if "require password immediately" is on) or synthesizing ⌃⌘Q through System Events, which needs Accessibility/Automation. Based on general knowledge and not verified against a source in this research.

### Gaps
- No public API was found for enumerating *other apps'* App Intents or the macOS 26 Spotlight action catalog from a third-party app.
- Not verified whether every `.searchTerms` anchor is accepted by the `x-apple.systempreferences:` URL handler, or whether the legacy versus new identifier works for each pane on 26.x. Needs a runtime test, for example `open "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"`.
- `Privacy_Pasteboard` did not appear among the `.searchTerms` anchors, so the searchTerms list is not a complete anchor list.

---

## Q5. Permissions UX (FDA, Accessibility, Automation, App Data, Pasteboard) and App Sandbox / distribution

### Takeaway
- **Full Disk Access:** no query or request API exists. Detect it by trying to read a TCC-protected file (Safari `Bookmarks.plist`/`CloudTabs.db`, `TCC.db`), then deep-link to `Privacy_AllFiles`.
- **Distribution:** an indexer that reads Safari/Chrome/Firefox data, other apps' containers, or arbitrary folders, and wants to paste into other apps, is a much better fit for **Developer ID (non-sandboxed, notarized)** distribution. Mac App Store apps must be sandboxed, and Apple DTS says the Accessibility APIs aren't supported in the sandbox.

### Cited Findings
- **How PermissionsKit (MacPaw, MIT) detects FDA:** it tries `open(path, O_RDONLY)` on `~/Library/Safari/CloudTabs.db`, `~/Library/Safari/Bookmarks.plist`, `~/Library/Application Support/com.apple.TCC/TCC.db` and `/Library/Preferences/com.apple.TimeMachine.plist`. To request access it opens `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`. — [GitHub: MacPaw/PermissionsKit `MPFullDiskAccessAuthorizer.m` lines 69–140](https://github.com/MacPaw/PermissionsKit)
- **inket/FullDiskAccess (MIT):** "Apps cannot enable Full Disk Access automatically". On macOS 10.15+, checking `isGranted` "will automatically add your app to the Full Disk Access entries in Privacy & Security (unchecked)". It also provides `openSystemSettings()` and a prompt helper. The package targets apps that are "not sandboxed". — [GitHub: inket/FullDiskAccess README](https://github.com/inket/FullDiskAccess)
- **Mac App Store requires the sandbox:** "Mac App Store apps must be sandboxed", so the sandbox cannot be turned off for App Store distribution. — [Apple Developer Forums thread 696586 (Quinn)](https://developer.apple.com/forums/thread/696586)
- **FDA for sandboxed apps:** a forum reply says only the user can grant FDA, and a sandboxed app still needs user-selected folder access as well. — [Apple Developer Forums thread 812999](https://developer.apple.com/forums/thread/812999)
- **Accessibility in the sandbox:** Apple DTS said the Accessibility APIs aren't supported in sandboxed apps. A sandboxed clipboard manager was rejected twice under Guideline 2.4.5 for using `CGEvent.post` to synthesize ⌘V. Other developers report `AXIsProcessTrusted` always returning false in sandboxed builds. — [Apple Developer Forums thread 820594](https://developer.apple.com/forums/thread/820594); [thread 810677](https://developer.apple.com/forums/thread/810677); [App Sandbox tag](https://developer.apple.com/forums/tags/app-sandbox)
- **App Data protection (macOS 14+):** opening files in another app's data container triggers "<App> would like to access data from other apps". The grant is transient, lasting only the process lifetime per an Apple DTS answer, which is why the prompt can recur. A macOS 26 report logs these under `kTCCServiceSystemPolicyAppData` and says FDA did not suppress them for a standalone CLI binary; that is a single report. Developers can use the `NSDataAccessSecurityPolicy` Info.plist key to allow-list access to their *own* containers. — [Apple Developer Forums thread 742147](https://developer.apple.com/forums/thread/742147); [Michael Tsai: Privacy and Security in macOS 14](https://mjtsai.com/blog/2023/06/15/privacy-and-security-in-macos-14); [claudeissues.com report](https://claudeissues.com/issue/79674-repeated-macos-26-tahoe-app-data-tcc-prompts-for-standalone-cli-binary)
- **Pasteboard (15.4+):** the "Paste from Other Apps" pane and the `accessBehavior` property, as covered in Q2. — [Local verification: NSPasteboard.h]; [Michael Tsai blog](https://mjtsai.com/blog/2025/05/12/pasteboard-privacy-preview-in-macos-15-4/)
- **Settings search keywords for these panes (Korean):** "Privacy_ListenEvent" = 키보드 입력 모니터링 (Input Monitoring); "Privacy_Accessibility", "Privacy_Automation" and "Privacy_AllFiles" are anchors in the PrivacySecurity `.searchTerms`. — [Local verification]

### Inferences
**Onboarding checklist.** Each permission should be optional and degrade gracefully:

| Feature | Permission needed | How to detect and request |
|---|---|---|
| Safari history/bookmarks | FDA | Detect with a protected-file read probe; deep-link to `Privacy_AllFiles` |
| Chromium/Firefox history | None (non-sandboxed app) | — |
| Clipboard history | Pasteboard "Allow" where enforced | Check `accessBehavior`; deep-link to `Privacy_Pasteboard` |
| Paste-into-front-app | Accessibility | `AXIsProcessTrustedWithOptions` with the prompt option; deep-link to `Privacy_Accessibility` |
| AppleScript system actions | Automation for System Events/Finder | Requires the `NSAppleEventsUsageDescription` Info.plist key; macOS prompts on first send |
| Folders the user picks | None beyond the user's choice | Security-scoped bookmarks |

- **Developer ID + notarization** is the practical distribution route. A Mac App Store build would have to drop or limit browser history, Safari, auto-paste and broad crawling.
- **Restart behavior:** FDA changes take effect without a restart for new file opens in most reports, while some TCC changes need an app relaunch. Plan a "Recheck" button. This is general knowledge and was not sourced here.

### Gaps
- No official Apple documentation was retrieved for FDA detection. Every approach found relies on probing protected files.
- Whether Accessibility-based paste is allowed in Mac App Store builds in 2026 is not settled; forum evidence is mixed.
- Re-prompt cadence for Screen Recording or Accessibility on macOS 15/26 is not relevant to this indexer and was not researched.

---

## Q6. Privacy: local encryption, exclusions, retention

### Takeaway
- **Treat the index as sensitive.** Clipboard text, OCR of screenshots and browsing history are among the most sensitive data on a Mac.
- **Follow nspasteboard.org:** don't record Transient or AutoGenerated items, and obfuscate or avoid persisting Concealed ones.
- **Defaults:** exclude password managers by bundle ID, apply size and time retention limits, and encrypt at rest beyond FileVault (for example SQLCipher or CryptoKit with a Keychain-held key).
- **Expose controls:** pause, delete-by-source and wipe.

### Cited Findings
- **Concealed data:** nspasteboard.org says concealed data should be visually obfuscated, and recommends "Avoid recording it to a file, or consider encrypting it". Transient data "should not be recorded or displayed". — [nspasteboard.org](https://nspasteboard.org/)
- **Maccy's privacy controls:**
  - Ignored types: TransientType, ConcealedType and AutoGeneratedType are always ignored, and users can add more types.
  - Ignored apps: an exclusion list, or an allow-only mode via `ignoreAllAppsExceptListed`.
  - Regex filters: `ignoreRegexp`.
  - Default history size: 200 items.
  - Storage: a local SwiftData SQLite store under Application Support; no encryption was visible in `Storage.swift`.
  - [GitHub: Maccy Clipboard.swift](https://github.com/p0deje/Maccy/blob/master/Maccy/Clipboard.swift); [Defaults.Keys+Names.swift](https://github.com/p0deje/Maccy/blob/master/Maccy/Extensions/Defaults.Keys%2BNames.swift); [Storage.swift](https://github.com/p0deje/Maccy/blob/master/Maccy/Storage.swift)
- **Apple's macOS 26 Spotlight clipboard history:**
  - It is off by default and has time-based retention: third-party guides cite 30 min / 8 h / 7 days, with sources conflicting.
  - One guide warns that Spotlight "will remember everything that you copy", including passwords.
  - Another says clipboard items were shown unredacted during screen recording in the initial Tahoe release.
  - [AppleInsider](https://appleinsider.com/inside/macos-tahoe/tips/spotlight-got-a-huge-upgrade-in-macos-tahoe-heres-how-to-use-it); [Paste blog](https://pasteapp.io/blog/macos-tahoe-clipboard-history); [ntiva](https://support.ntiva.com/hc/en-us/articles/39853826658701-macOS-Tahoe-Disable-Clipboard-History-in-Spotlight)
- **Chrome encrypts its own embeddings:** Chrome's own AI history embeddings are reportedly compressed and encrypted on disk, and private browsing is excluded. — [dejan.ai analysis](https://dejan.ai/blog/inside-chromes-semantic-engine-a-technical-analysis-of-history-embeddings/)
- **Chrome flags password state:** Chrome's `content_annotations` has a `password_state` column, so Chrome marks pages that involved passwords. A launcher could use this to skip such visits. — [Local verification: Chrome History schema]
- **Core Spotlight's local index:** the app's donated index is "private, entirely local … never leaves the device"; other apps cannot see it. This is a model for keeping the launcher's own index local. — [WWDC24 10131](https://developer.apple.com/videos/play/wwdc2024/10131/)

### Inferences
**Recommended policy defaults:**
1. Clipboard capture off until the user enables it; then exclude 1Password (`com.1password.1password`), Bitwarden, KeePassXC, Apple Passwords and Keychain Access by bundle ID, and drop items with nspasteboard markers.
2. Default retention: clipboard 7–30 days or N items; browser history 90 days (configurable); files tied to their existence (remove vectors on delete via FSEvents).
3. Encryption at rest:
   - Rely on FileVault plus file protection.
   - Optionally use SQLCipher or per-row AES-GCM (CryptoKit) for clipboard and history text, with the key in the Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`).
   - Embeddings themselves can leak content (inversion attacks), so encrypt the vector store too, or keep it in the same encrypted container.
4. Never index private/incognito data (browsers don't write it to History) or Chrome visits with `password_state != 0`.
5. Add a "pause indexing" menu-bar toggle and a "forget this site/app" action that deletes both the text and the vectors.
6. Show source attribution (`org.nspasteboard.source` / frontmost app) next to clipboard results.

### Gaps
- No authoritative benchmark or source was found on the overhead of SQLCipher-encrypted vector stores on Apple Silicon.
- No Apple guidance was found on retention for third-party clipboard managers. Apple's own Spotlight retention options come from third-party descriptions, not Apple documentation.
