# AGENTS.md

Instructions and guidelines for AI coding agents (Antigravity, Codex, etc.) working in this repository.

## Build and Test Commands
- **Build**: `swift build`
- **Run Tests**: `swift test`
- **Run App**: `.build/arm64-apple-macosx/debug/MarginGraphApp`

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
5. **Mandatory Post-Implementation UI & App Testing**: Whenever you finish implementing changes, you MUST launch the app (`.build/arm64-apple-macosx/debug/MarginGraphApp`), interact with the application, click around, and test the functionality and UI yourself to verify everything is working properly before declaring completion. Never ask or rely on the user to test what you can verify yourself.
6. **Boundary Containment for All Buttons, Menus & Popovers**: Whenever adding or modifying ANY button, menu, popover, or dropdown, you MUST explicitly verify and guarantee that it stays strictly inside the application window boundaries. Never use native unbounded controls (such as AppKit `Menu` / `NSMenu` or default `.popover(...)`) near window or split-pane edges (e.g. right/trailing side of toolbars) where rightward or outward expansion bleeds past the program window. Always use in-window popovers (`InWindowPopoverContainer`) with dynamic horizontal clamping or explicit boundary constraints, and visually verify in live app testing.

### Mandatory Lesson Maintenance
Before completing any task where a bug was diagnosed, an unexpected framework behavior was solved, or an architectural pattern was introduced, **YOU MUST PROACTIVELY UPDATE [`.agents/rules/project-lessons.md`](.agents/rules/project-lessons.md)**.

