# AGENTS.md

Instructions and guidelines for AI coding agents (Antigravity, Codex, etc.) working in this repository.

## Build and Test Commands
- **Build**: `swift build`
- **Run Tests**: `swift test`
- **Run App**: `.build/arm64-apple-macosx/debug/MarginGraphApp`
- **Prepare App for Computer-Use UI Testing**: `bash scripts/prepare-ui-test-app.sh`

## Live UI Testing with Computer Use

Use this workflow for mandatory post-implementation UI verification:

1. Run `bash scripts/prepare-ui-test-app.sh` from the repository. It runs `swift build --product MarginGraphApp` and creates `.build/UITesting/MarginGraph.app`. Re-run it after source changes: the bundle contains a copied executable, which otherwise becomes stale. If the sandbox blocks Swift compiler cache access, request the normal tool escalation for this build command.
2. Use `mcp__cua_repl.js` to launch/select the bundle by its **absolute path** (substitute the current checkout path when working elsewhere):
   ```javascript
   let marginApp = await cua.getApp("/Users/broliang/git/margin-graph/.build/UITesting/MarginGraph.app");
   ```
   The standalone SwiftPM executable was rejected by the computer-use resolver by both name and path and did not appear in its app inventory. The `.app` wrapper resolves this; do not treat that failure as proof that computer use is unavailable. Its display name is `MarginGraph` and bundle identifier is `local.margingraph.ui-test`.
3. Read the returned accessibility tree, then interact through the documented `cua_repl` APIs. Use fresh element indices from the current tree, never hard-coded indices from previous sessions. After actions, call `await marginApp.getAXState()` before choosing the next action. Use `await marginApp.getScreenshot()` to inspect rendering and window boundaries; refresh the full tree before using indices after a screenshot-only observation.
4. At minimum, open an existing bookshelf document, verify the PDF and mind map render, and open/dismiss the reader's More menu. Inspect a screenshot to confirm that menu stays within the application window. These interactions have been verified with this setup. Also exercise the specific functionality changed, including relevant card clicks, scrolling, pane collapse/restore, or edge-positioned controls; a successful launch alone is insufficient.
5. Use non-destructive interactions with existing library content. Avoid imports, edits, or deletions unless required by the task and authorized. Quit the test app before rebuilding/relaunching when needed so an older running process is not mistaken for the new build. Report exactly what was verified and any concrete blocker.

The wrapper's `local.margingraph.ui-test` bundle identifier uses separate app preferences from the bare `MarginGraphApp` executable. Confirm the active library before reproducing a bug; aliases and startup defaults may differ. For the external library aliased `main`, the existing working database is `/Volumes/omv/backups/marginnote/main/MarginGraph.sqlite`; it can be opened through Manage Libraries → Add Library without importing the backup again. Compare performance using the same library and document, including a first open after restart and a subsequent reopen. Computer-use click/observation timings include tool overhead; a timeout followed by recovery bounds the freeze but does not provide an exact app-only duration. Use a CPU sample spanning the click to identify the blocked work.

Use `cua_repl` for UI interaction and screenshots. The bundle workflow satisfies the live-app launch requirement below. Automated tests remain necessary where applicable; UI smoke testing does not replace the mandatory pre-commit benchmark and layout tests.

## Architecture Overview
- **MarginGraphCore**: Core data models, SQLite storage layer, PDFKit interaction engine, and mindmap graph models.
- **MarginGraphApp**: Native macOS SwiftUI / AppKit application interface.

## Mandatory Rules & Lessons Learned
All agents working in this repository must strictly adhere to the guidelines and traps documented in:
👉 [`.agents/rules/project-lessons.md`](.agents/rules/project-lessons.md)

### Key Invariants to Respect
1. **SwiftUI Overlay Layout**: Never use `.position(...)` inside a `ZStack` for overlays or draggable controls; use `.frame(...)` + `.offset(...)` inside `ZStack(alignment: .topLeading)` to prevent full-window hit-test blocking.
2. **Gesture & View Decoupling**: Never continuously update heavy `PDFView` or canvas layout inside high-frequency `DragGesture.onChanged`; decouple with transient indicators (`liveDividerX`) and debounce or commit on `onEnded`.
3. **AppKit Cursor Reset**: Always restore `NSCursor.arrow.set()` and call `resetCursorRects()` in `DragGesture.onEnded` and view `.onDisappear`.
4. **SQLite Linkage & Tests**: System `sqlite3` is linked directly via `.linkedLibrary("sqlite3")`. Database tests must use in-memory SQLite (`try Database(inMemory: true)`).
5. **Mandatory Post-Implementation UI & App Testing**: Whenever you finish implementing changes, you MUST launch the freshly built app using the **Live UI Testing with Computer Use** workflow above, interact with the application, click around, and test the functionality and UI yourself to verify everything is working properly before declaring completion. Never ask or rely on the user to test what you can verify yourself.
6. **Boundary Containment for All Buttons, Menus & Popovers**: Whenever adding or modifying ANY button, menu, popover, or dropdown, you MUST explicitly verify and guarantee that it stays strictly inside the application window boundaries. Never use native unbounded controls (such as AppKit `Menu` / `NSMenu` or default `.popover(...)`) near window or split-pane edges (e.g. right/trailing side of toolbars) where rightward or outward expansion bleeds past the program window. Always use in-window popovers (`InWindowPopoverContainer`) with dynamic horizontal clamping or explicit boundary constraints, and visually verify in live app testing.
7. **Mandatory Pre-Commit Benchmark & Layout Tests**: Two automated tests (`testMandatoryBenchmarkDocumentOpenAndCardClickSpeed` and `testMandatoryMindMapLayoutZeroOverlapsAndRootIgnored`) MUST pass before every commit: document opening / card click responsiveness (< 500ms / < 100ms) and mindmap zero-overlapping card layout verification with synthetic document root cards ignored. Commits are strictly prohibited if either test fails.


### Mandatory Lesson Maintenance
Before completing any task where a bug was diagnosed, an unexpected framework behavior was solved, or an architectural pattern was introduced, **YOU MUST PROACTIVELY UPDATE [`.agents/rules/project-lessons.md`](.agents/rules/project-lessons.md)**.


## macOS File Permissions Across Rebuilds

The UI test bundle keeps the same bundle identifier, but a default ad hoc code signature identifies only one build. macOS file-location approvals can recur when executable code changes. Different protected locations may require separate initial approvals; bookmarks or app preferences cannot substitute for macOS privacy approval. The “data from other apps” container-protection prompt is a separate case: its consent can last only for the current app instance, even with stable signing. Do not promise signing will persist that approval. Startup loads catalog metadata without running filesystem synchronization, and shelf/notebook cover previews load durable PNGs from MarginGraph/CoverThumbnails before touching their source files. Generate and persist a missing cover asynchronously; do not suppress covers solely because a source is in another app’s container. Initial generation may require consent, but cached previews must work without source access.

`scripts/prepare-ui-test-app.sh` signs and verifies the entire bundle. It uses `MARGINGRAPH_SIGNING_IDENTITY` when set, otherwise an available Apple Development or Developer ID Application identity. Install a development signing identity through Xcode if none exists, then consistently build with that identity. For example:

```bash
MARGINGRAPH_SIGNING_IDENTITY='Apple Development: Your Name (TEAMID)' bash scripts/prepare-ui-test-app.sh
```

Keep the same signer and bundle identifier across builds. The script warns and uses ad hoc signing when no identity exists; that fallback does not promise approval persistence across code changes. Do not use identifier-only designated requirements, alter the TCC database, or grant Full Disk Access as a workaround. Verify with `codesign -d -r- .build/UITesting/MarginGraph.app`, restart without rebuilding, and then repeat after a rebuild signed by the same certificate. Only claim cross-build persistence after verifying that path.
