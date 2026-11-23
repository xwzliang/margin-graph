# Project Lessons & Mandatory Engineering Rules

> [!IMPORTANT]
> **MANDATORY AGENT WORKFLOW RULE**:
> 1. **Before any coding, debugging, or refactoring**: Consult the lessons and traps in this file to avoid re-introducing documented regressions or fighting known framework pitfalls.
> 2. **Before concluding ANY task**: If the task involved diagnosing an unexpected bug, fixing broken behavior (such as blocked clicks, layout shifts, coordinate offsets, performance lag, or stuck cursors), or learning a non-obvious framework behavior (SwiftUI, AppKit, PDFKit, SQLite), **YOU MUST PROACTIVELY UPDATE THIS FILE** before declaring completion.
> 3. **Definition of Done**: Updating this file with verified traps and durable rules is part of the definition of done for non-trivial tasks. Do not wait for the user to ask or remind you.
> 4. **Mandatory Post-Implementation UI & App Testing**: Whenever you finish implementing, ALWAYS launch the app (`.build/arm64-apple-macosx/debug/MarginGraphApp`), interact with the application, click around, and test the functionality and UI yourself to verify everything is working properly before declaring completion. Never ask or rely on the user to test what you can verify yourself.
> 5. **Mandatory Pre-Commit Benchmark & Layout Tests**: Before every git commit, you MUST run and pass `testMandatoryBenchmarkDocumentOpenAndCardClickSpeed` (document open < 500ms, card click < 100ms) and `testMandatoryMindMapLayoutZeroOverlapsAndRootIgnored` (0 bounding box overlaps in mindmap layout, synthetic document root cards ignored). Commits are strictly prohibited if either test fails.

---

## Lesson Maintenance Protocol

### Mandatory Update Triggers
Add or refine a lesson whenever:
- **Root Cause Diagnosed**: Non-obvious failure cause was identified (e.g. event interception, coordinate shifts, view thrashing).
- **Framework Quirk Discovered**: An unexpected behavior in SwiftUI, AppKit, PDFKit, or SQLite was solved with a specific workaround.
- **Architectural Invariant Established**: A design decision was made that must be maintained across sessions to avoid regressions.
- **Tooling / Test Gotcha Encountered**: A specific build command, test isolation requirement, or setup step was learned.

### Entry Format
Structure each entry concisely with actionable rules:
- **Trap / Problem**: Concise description of symptom and root cause.
- **Rule / Invariant**: Concrete coding rule or pattern to prevent recurrence.

### What NOT to Add
- One-off temporary debugging states or scratch script paths.
- Secrets, credentials, or personal information.
- Unverified hypotheses or narrative conversation history.


## Architecture & Conventions
- SQLite Linkage: Targets link system `sqlite3` directly using `.linkedLibrary("sqlite3")` without third-party package dependencies.
- Test Isolation: Database unit tests should always initialize in-memory SQLite instances (`try Database(inMemory: true)`) to prevent filesystem pollution and test interference.
- Swift Concurrency: `Database` uses a recursive lock and `@unchecked Sendable` for serialized access. Hold the lock across the entire transaction so operations on another thread cannot join it. Get user input before acquiring the transaction lock.

## SwiftUI Layout & Hit-Testing Traps
- **Never use `.position(x:y:)` for floating overlays or draggable controls in a `ZStack`**:
  In SwiftUI, `.position(x:y:)` silently expands the view's layout container to the **entire proposed parent frame** (full window width and height). If that view has gestures (`DragGesture`, `.simultaneousGesture`), hover handlers (`.onHover`), or a high `zIndex`, it forms an invisible full-window hit-test shield that intercepts all mouse clicks, scroll events, card selections, and tooltips across the app. Always use explicitly sized `.frame(width: w, height: h)` and `.offset(x: ..., y: ...)` instead.
- **Anchor overlay `ZStack` containers to `.topLeading`**:
  In SwiftUI, `ZStack(alignment: .leading)` defaults vertical alignment to `.center` (`totalHeight / 2`), and `ZStack(alignment: .trailing)` defaults horizontal alignment to `totalWidth`. Adding offsets like `y: totalHeight * 0.74` inside `.leading` pushes the element to `1.24 * totalHeight`, moving it completely off-screen below the window. Standardize multi-layer coordinate overlays on `ZStack(alignment: .topLeading)` so that `(0, 0)` is top-left and all offsets are strictly deterministic.

## Performance & View Thrashing
- **Decouple high-frequency gestures from heavy AppKit / PDFKit views**:
  Continuously updating geometry state controlling an AppKit `PDFView` or large MindMap canvas inside `DragGesture.onChanged` forces continuous subview re-layout, page break recalculations, and tile rasterizations up to 120 times/second, causing severe lag and hangs. Always decouple transient drag state:
  - Track a lightweight indicator (e.g. `liveDividerX`, split pill, and guide line) during drag.
  - Keep heavy views at their last committed width during active motion.
  - Debounce the layout commit (e.g. 100ms pause) or commit strictly upon `onEnded`.

## AppKit Cursor & Window Management
- **Explicitly reset cursors in `onEnded` and `onDisappear`**:
  During active mouse dragging, SwiftUI/AppKit hover exit events are dropped if the cursor leaves the view boundary before mouse-up, leaving cursors permanently stuck as `resizeLeftRight`. Always explicitly restore `NSCursor.arrow.set()` and refresh `NSApp.keyWindow?.resetCursorRects()` in `DragGesture.onEnded` and view `.onDisappear`.
- **Dynamic Boundary Clamping for Tooltips & Popovers**:
  Floating tooltips and popovers positioned relative to edge-aligned buttons can bleed past window edges. Always clamp tooltip offsets using `min(max(minPadding, rawX), totalWidth - tooltipWidth - minPadding)`.

## MarginNote Package (.marginpkg) Import & Conflict Resolution
- **`.marginpkg` Archive & CoreData Structure**:
  `.marginpkg` files are PKZip archives containing document files (`.pdf`) and an SQLite database (`.marginnotes`). In `.marginpkg` files, the `ZBOOK` table is frequently empty (0 rows) while `ZBOOKCONFIG` contains the book's metadata (`ZTITLE`, `ZMD5`, and `ZMD5LONG`). The importer must check `ZBOOKCONFIG` to obtain `ZMD5LONG`, which matches `ZBOOKMD5` in `ZBOOKNOTE` and `ZLOCALBOOKMD5` in `ZTOPIC`.
- **Document Staging & Persistence**:
  Extracted documents from `.marginpkg` must be staged into persistent application storage (`~/Library/Application Support/MarginGraph/Documents/`) rather than temporary directories so they remain accessible across app launches.
- **Native Conflict Resolution Flow**:
  When an incoming topic title matches an existing topic (case-insensitive trimmed), present an `NSAlert` modal with `Merge`, `Replace`, and `Cancel` (with Escape bound to cancel). `Merge` preserves the existing topic ID and appends new document MD5s and re-parents cards; `Replace` deletes old topic cards/links and inserts new ones; `Cancel` aborts with zero database mutations.
- **Document ID Collision & Replacement Bug**:
  In MarginNote SQLite exports, every package starts its row IDs at `Z_PK = 1`. If document IDs are derived from `stableUUID(Z_PK)`, every imported package produces the exact same document UUID (`stableUUID("1")`). Under `INSERT OR REPLACE INTO documents`, importing a new document silently overwrites previous documents with the same ID, capping the shelf count (e.g. at 3) and replacing previous books. Always generate document IDs using `Document.stableUUID(md5)` (derived from the unique content hash). In `Database.insertDocument`, prevent ID collisions from replacing distinct documents with different MD5s, and run `repairDocumentIDs()` on initialization.
- **Sidecar `.pdf.md5` and Document Library Synchronization**:
  MarginNote stores its 64-character SHA-256 book hash in `ZMD5LONG` and sidecars it as `<path>.pdf.md5`. `PDFDocumentManager` and the importer must always check for this sidecar before hashing raw bytes. Implement automatic startup synchronization (`syncAvailableDocuments()`) to discover documents from both MarginNote sandboxes and Application Support, repair moved file paths, and ensure all library documents appear on the shelf.
- **Startup Performance & Avoid Synchronous Full Re-Imports**:
  - Main thread startup in `AppModel.init()` must be sub-100ms.
  - The condition in `autoImportLiveMarginNoteIfEmpty()` must strictly guard on `existingTopics.isEmpty || totalCards == 0`. Never check transient or easily invalidated conditions (like document counts or empty file paths) for triggering auto-import, or else every app launch will synchronously re-parse 400+ topics and 4,000+ cards on the main thread, locking the UI for 10-15 seconds.
  - In `syncAvailableDocuments()`, always check if a document's MD5 is already registered and points to an existing file before creating a `PDFKit.PDFDocument` instance. Re-parsing PDF files on every startup destroys app launch performance.
- **MarginNote iCloud Phantom Book Overwrite & Multi-Book Topics**:
  - In full MarginNote library databases (`MarginNotes.sqlite`), `ZBOOKCONFIG` contains hundreds of iCloud placeholder records without physical file paths (`filePath = ""`). Only inspect `ZBOOKCONFIG` when `ZBOOK` has 0 rows (e.g. single-book `.marginpkg` files).
  - Never allow documents with empty `filePath` to be inserted or to overwrite valid documents in SQLite (`insertDocument`).
  - Never assign the full library document list to a topic's `bookMD5List`. Parse `ZLOCALBOOKMD5` (splitting on `"|"` to support multi-book topics), or harvest `bookMD5` from the topic's cards.
- **In-Memory SQLite Unit Tests vs Filesystem Existence Checks**:
  - Core database query methods (e.g. `documentsForTopic`) and in-memory databases (`Database.isInMemory`) must never reject mock documents purely because `FileManager.default.fileExists(atPath: $0.filePath)` is false. In unit tests, mock documents use synthetic paths (e.g. `/tmp/one.pdf`) which do not exist on disk.
  - Filter on `!$0.filePath.isEmpty` and prioritize files that exist on disk using `.sorted { (fileExists($0) ? 1 : 0) > (fileExists($1) ? 1 : 0) }`, preserving test isolation while maintaining robustness in production.
- **Document Deduplication by Physical File Path (`filePath`)**:
  - A physical file on disk represents exactly one document in the library. If multiple records are created (e.g. one with raw fallback MD5 and one with MarginNote's official SHA-256 hash), `insertDocument` and `syncAvailableDocuments` must detect matching non-empty `filePath` values, select the authoritative document (prioritizing records with cards / 64-char hashes), migrate cards and topics, delete stale duplicate rows, and write the winning MD5 to `<filePath>.md5`.
- **SQL Parameterization & Single Quote Escaping**:
  - Never interpolate unescaped strings directly into SQL queries (e.g. `DELETE FROM documents WHERE file_path = '\(doc.filePath)'`). File titles such as *Save the Cat! The Last Book on Screenwriting You'll Ever Need* contain single quotes (`'`) which break query syntax (`near "ll": syntax error`). Always use parameterized statements (`withStatement` with `sqlite3_bind_text`).
- **SQLite Concurrency & Busy Timeout**:
  - Always configure `PRAGMA busy_timeout = 5000;` and `PRAGMA journal_mode = WAL;` (for disk databases) on SQLite initialization. Without a busy timeout, any transient concurrent access or background test run will immediately fail with `sqlite("database is locked")`.
- **Preventing $O(N^2)$ Query Loops in Maintenance Passes**:
  - When cleaning up or auditing topics in database sync routines, never query SQLite inside nested loops (e.g. calling `cardsForTopic` inside a topic comparison loop across 400+ topics, resulting in ~190,000 queries). Instead, fetch aggregated counts upfront (e.g. `cardCountsByTopic()`) in a single query and perform comparisons in memory.

## View State Persistence Across Workspace Collapses & Mode Transitions
- **Never unmount heavy views (`InteractivePDFView`, `MindMapCanvasView`) across workspace layout modes**:
  Conditionally switching view branches with `switch model.workspaceMode` (`case .readerOnly: ... case .mindMapOnly: ...`) destroys the unmounted pane and tears down its AppKit/SwiftUI hierarchy. Upon restoring split view, the pane is recreated from scratch, wiping out the user's scroll location, page index in PDF, and pan/zoom coordinates in MindMap. Keep both panes mounted simultaneously in a unified `ZStack(alignment: .topLeading)` layout:
  - When collapsing to `.readerOnly`: keep `mindMapPane` mounted but offset off-screen (e.g. `x = -mindMapWidth - 100`) with `.opacity(0).allowsHitTesting(false)`.
  - When collapsing to `.mindMapOnly`: keep `pdfPane` mounted but offset off-screen (e.g. `x = totalWidth + 100`) with `.opacity(0).allowsHitTesting(false)`.
  - Save `savedSplitPDFWidth` before changing mode and restore it upon clicking the edge restore handles or toolbar button.
- **Guard Viewport Fitting on Reappearance**:
  In canvas views like `MindMapCanvasView`, guard `viewport.zoomToFit(...)` with a state flag (`hasInitialFitted`) so it only runs once per topic load, and never resets zoom/pan during window resizing or layout collapse/restore transitions. Similarly, ignore zero-size dimensions (`guard size.width > 20 && size.height > 20`) in `.onChange(of: proxy.size)` to prevent zero-width collapses from corrupting canvas viewport calculations.
- **Persist PDF Read Position Across Components & Containers**:
  Bind `currentPageIndex` to application model state (`documentCurrentPage: [String: Int]`) via `onPageChanged`. Upon initializing `InteractivePDFView` (`makeNSView`), if `currentPageIndex > 0`, explicitly call `view.go(to: page)` so the document instantly restores its last read position even if recreated.
- **Mutual Exclusion for Dedicated Toolbars**:
  When multiple inspection toolbars exist (e.g. PDF popover toolbar vs MindMap card toolbar), guard visibility strictly by ownership (`activeToolbarOwner`). When a note card is clicked in MindMap, set `activeToolbarOwner = .mindMap` and guard `InteractivePDFView.updateToolbarPosition()` with `guard activeToolbarOwner == .pdf else { hideToolbar(); return }` to prevent the PDF popover from inadvertently showing.
- **SwiftUI `ZStack` Intrinsic Sizing & Centering Trap with `.offset(...)`**:
  In SwiftUI, `.offset(x:y:)` only affects drawing position and does NOT update a view's layout footprint. A `ZStack` calculates its layout frame from the union of its children's un-offset frames. If a `ZStack` containing offset children is given `.frame(maxWidth: .infinity, maxHeight: .infinity)` (which defaults to `.center` alignment), SwiftUI will center the un-offset `ZStack` inside the parent window.
  For example, in a 1024px window with two 512px panes where the second pane is offset by 512px, the `ZStack`'s intrinsic layout width is only 512px. Centering that 512px box in a 1024px window shifts the entire workspace right by `(1024 - 512) / 2 = 256px`, leaving a massive 256px blank column of window background on the left and pushing the right 256px off-screen.
  **Rule**: When using `.offset` to position sibling panes inside a `ZStack`, always pin the `ZStack` container explicitly using `.frame(width: totalWidth, height: totalHeight, alignment: .topLeading).clipped()`.
- **TreeLayout Card Sibling & Child Insertion Ordering**:
  When inserting a new note card (`createSiblingCard` or `createChildCard`), if `mindPos` is `nil`, `TreeLayout.cardOrder` treats `nil` as `.greatestFiniteMagnitude` compared to existing cards (imported from MarginNote) that have valid `mindPos.y` values. As a result, the new card is sorted to the very bottom of the entire notebook or subtree, thousands of pixels away from the clicked card, appearing as if no card was created.
  **Rule**: When creating a sibling or child, look up adjacent siblings using `TreeLayout.cardOrder`, interpolate `mindPos.y` (e.g. `(sibling.mindPos.y + nextSibling.mindPos.y) / 2` or `sibling.mindPos.y + 100`), and interpolate `createdAt`. In `MindMapCanvasView.onChange(of: cards)`, automatically re-center `viewport.center(on: frame)` when `selectedCardID` matches a newly inserted card.
- **SwiftUI Label Truncation in Floating Toolbars**:
  In floating toolbars with multiple buttons and color swatches, SwiftUI may greedily truncate text labels (e.g. displaying `"Sib..."` instead of `"Sibling"`) if the toolbar frame width is constrained.
  **Rule**: Always apply `.fixedSize(horizontal: true, vertical: false)` to button text labels in floating toolbars, and size the toolbar frame with adequate width buffer (e.g. 380px) to prevent truncation.

- **Unified Top Toolbar Height Across Split Panes**:
  - **Trap**: Relying on vertical padding (`.padding(.vertical, 7)`) for top toolbars across sibling panes (e.g. Outline Sidebar, MindMap View, and PDF View). Sibling view hierarchies often contain buttons or controls of different intrinsic heights (e.g. 32pt in MindMap header vs 28pt in PDF toolbar vs 24pt in search bar). Symmetric vertical padding results in mismatched total bar heights (e.g. 46pt vs 42pt), breaking horizontal alignment of bottom separator lines across the divider.
  - **Rule**: Standardize top toolbars to an explicit shared height constant (`MarginNoteTheme.topToolbarHeight: CGFloat = 44.0`) with identical bottom overlay separator lines (`Rectangle().frame(height: 0.5).foregroundStyle(MarginNoteTheme.separatorColor), alignment: .bottom`) so all headers align into an unbroken horizontal line across the entire window.

- **Co-Updating Document & Study Recency vs Isolated Review Deck Recency**:
  - **Trap**: Leaving view recency updates uncoordinated or tangled. Opening a document did not touch its study notebook (or vice-versa), so the default "Recent" sort left related items detached or stale. Tangling deck reviews with study notebook timestamps would cause reviewing flashcards to reshuffle the Study notebook page.
  - **Rule**:
    1. **Document & Study Synchronization**: When opening a document or switching documents in reader/workspace, touch both `document.lastVisited` and `matchingTopic.updatedAt` to `Date()`. Similarly, when opening a notebook for study, touch `topic.updatedAt` and all associated documents' `lastVisited` to `Date()`. This ensures that recently viewed documents and notebooks always sort to the top together.
    2. **Isolated Review Deck Recency**: Track review deck recency independently via a dedicated `deck_reviews` table storing `last_reviewed` timestamps. In `ReviewDecksView`, sorting by "Recent" strictly checks `lastReviewed`, moving reviewed decks to first place without perturbing the Document or Study notebook sort orders.

## Inline Canvas Text Editing & Gesture Disambiguation
- **Disambiguating Single Tap vs Double Tap on Canvas**:
  In SwiftUI on macOS, attaching both `.onTapGesture(count: 2)` and `.onTapGesture(count: 1)` to the same view without explicit exclusion causes the single-tap gesture to fire immediately on the first click of a double-click sequence, creating a race condition where single-tap deselects or commits state right as double-tap creates a note.
  **Rule**: Use `SpatialTapGesture(count: 2, coordinateSpace: .named(...)).exclusively(before: SpatialTapGesture(count: 1, coordinateSpace: .named(...)))` so the system waits for the double-click timeout before recognizing single tap, guaranteeing mutual exclusion.
- **Preventing Canvas Shortcut Interception During Inline Text Editing**:
  When canvas-level keypress modifiers (`.onKeyPress(.return)`, `.onKeyPress(.tab)`, `.onKeyPress(.delete)`, `.onKeyPress(.space)`) are active, typing inside an embedded text field (like an inline title editor) will trigger canvas shortcuts (e.g. creating siblings, deleting cards, or opening modals) while typing unless guarded.
  **Rule**: Always pass an `isEditingTitle: Bool` flag to keyboard handler modifiers and check `guard !isEditingTitle else { return .ignored }` before handling any canvas key commands. In the `NSViewRepresentable` text field delegate (`doCommandBy selector`), consume Return (`insertNewline`) and Tab (`insertTab`) to commit edits and return `true` so AppKit marks the command handled.
- **Decoupling Title Double-Click from Card Body Double-Click**:
  In mindmap cards, double-clicking the title area should trigger inline title editing directly on the canvas without showing a popup window, whereas double-clicking the excerpt or note body should open the full inspector / edit sheet.
  **Rule**: Separate tap gesture zones inside `CardNodeView`: place `.onTapGesture(count: 2) { onStartEditTitle?() }` on the accent header HStack, and place `.onTapGesture(count: 2) { onEdit?() }` on the body excerpt VStack.
- **AppKit `NSViewRepresentable` Text Field Focus & State Guarding**:
  1. `NSTextField` created dynamically in SwiftUI may not yet have its `window` attached during `makeNSView`. Claim first responder in both `makeNSView` (`DispatchQueue.main.async`) and `viewDidMoveToWindow` via `self.window?.makeFirstResponder(self)` followed by `self.selectText(nil)`.
  2. In `updateNSView`, never mutate `nsView.stringValue = text` if `nsView.currentEditor() != nil`. When `currentEditor() != nil`, the user is actively typing in the field editor; resetting `stringValue` causes cursor jumps and disrupts input.
  3. Reset `context.coordinator.hasCommitted = false` in `updateNSView` when `currentEditor() == nil` to ensure reused text field coordinators properly commit subsequent edits.

- **Free Note Canvas Placement vs Auto-Layout Packing**:
  - **Trap**: `TreeLayout.layout` unconditionally packed every root card at `(columnStartX = 40, nextY)` in column 1, ignoring `card.mindPos`. When double-clicking or right-clicking on empty canvas at `(x, y)`, the note was created in the database at `(x, y)`, but the layout engine immediately snapped it to column 1 at `(40, y)`.
  - **Rule**: In `TreeLayout.layout`, partition root cards into `anchoredRoots` (free notes: `groupNoteId == nil && bookMD5 == nil && startPage == nil && mindPos != nil`) and `autoRoots`. Place anchored roots directly at `origin: card.mindPos!`, with any child branches emerging to their right (`placeAnchored`), leaving column 1 packing exclusively for document excerpt auto-roots.

- **Container `DragGesture` Swallowing Child Double-Click & Text Selection**:
  - **Trap**: Attaching `DragGesture` without `minimumDistance` to the outer card container captures mouse-down immediately, canceling child double-click gestures (`TapGesture(count: 2)`) and hijacking text selection inside `NSTextField`. Handling `distance <= 3` inside `onEnded` to simulate tap fires on the first click and destroys multi-click sequences.
  - **Rule**: Always specify `DragGesture(minimumDistance: 4, ...)`. Never handle `distance <= 3` inside `onEnded` when child views have their own tap gestures. Furthermore, completely disable the container drag gesture during inline editing using `.gesture(nodeDrag(...), including: isEditingTitle ? .none : .all)`, and disable header tap gestures with `including: isEditingTitle ? .none : .all`.

- **AppKit Cursor Rects in Overlay Views over `PDFView`**:
  - **Trap**: `PDFView` registers a full-view I-beam cursor rect on its internal document view. Subviews hosted in `NSHostingView` don't register cursor rects by default, so AppKit falls back to the parent `PDFView`'s I-beam cursor even when hovering over toolbar buttons.
  - **Rule**: Subclass `NSHostingView` as `ToolbarHostingView`, override `resetCursorRects()` to `discardCursorRects(); addCursorRect(bounds, cursor: .arrow)`, and add an `NSTrackingArea` with `[.mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect]`. In SwiftUI, apply `.onHover { hovering in if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() } }` for button hover feedback.

- **MarginNote 3 Branch Collapse/Expand Connector Button Design**:
  - **Trap**: Placing chevron collapse/expand buttons inside the card header violates MarginNote design parity and clutters the title bar.
  - **Rule**: Render branch collapse/expand buttons directly on the outgoing connector line at `(frame.maxX + 14, frame.midY)` as a circular 15pt white badge with accent stroke and inner `⊖` (expanded) or `⊕` (collapsed). Draw a short horizontal stem for folded nodes from `(parent.maxX, parent.midY)` to `(parent.maxX + 14, parent.midY)` to connect the card to the toggle button.

- **Guard Viewport Centering: Selection vs Explicit Card Moves**:
  - **Trap**: Applying a blanket rule: either centering unconditionally on every selection click (which causes jarring viewport jumps during ordinary reading), OR guarding all centering behind `!viewRect.insetBy(dx: 40, dy: 40).contains(screenRect)` (which prevents moved cards from centering if the destination is still within the visible screen, leaving the moved card at the edge and disorienting the user).
  - **Rule**: Distinguish card selection clicks from explicit card movements:
    1. **Selection clicks (`onChange(of: selectedCardID)`)**: Guard with `!viewRect.insetBy(dx: 40, dy: 40).contains(screenRect)` so selecting already visible cards does not jerk the canvas.
    2. **Explicit Card Moves (`nodeDrag.onEnded` or `onChange(of: cards)` with `didMove` / `cardIDToCenter`)**: Smoothly center on the card (`withAnimation(.easeInOut(duration: 0.25)) { viewport.center(on: frame) }`). This ensures that after dragging a card to a new column grid slot, reparenting, or performing undo/redo, the moved card is reliably centered in the viewport.

- **SwiftUI `TextField` vs `NSViewRepresentable` `NSTextField` for Inline Canvas Editing**:
  - **Trap**: Using `NSViewRepresentable` wrapping `NSTextField` for in-place inline editing in a SwiftUI canvas/card view causes instant dismissal: AppKit fires `controlTextDidEndEditing` (with `NSOtherTextMovement` / blur) during view mounting, initial responder negotiation, or parent layout shifts (such as docked action bar appearance changing card height). Calling `onCommit()` inside `controlTextDidEndEditing` immediately clears editing state (`editingCardTitleID = nil`) before the user can type a single character.
  - **Rule**: Use a native SwiftUI `TextField` with `@FocusState` for inline editing. Set `isFocused = true` on appear, commit via `.onSubmit`, cancel via `.onExitCommand`, and blur-save via `.onDisappear` guarded with a `hasCommitted` boolean flag. In `onStartEditTitle`, avoid redundant card selection state mutations if the card is already selected.

- **`HStack` Compression and Text Collisions from `minWidth` on Button Hit Targets**:
  - **Trap**: Adding `.frame(minWidth: 26)` to a general button hit target modifier inside an `HStack` informs SwiftUI that the button layout frame can be compressed down to 26pt. If inner text labels have `.fixedSize(horizontal: true, vertical: false)` (such as `"Add to comments"`, `"As title"`, `"Merge"`), the text renders at full intrinsic width (e.g. 110pt) while adjacent buttons are placed based on the 26pt frame, causing severe text bleeding and overlapping collisions (`As titleAdd to commentsMerge`).
  - **Rule**: Only apply `minWidth: 26` to small icon-only buttons (e.g. `trash`, `tag`, `sparkles`). Text buttons must use intrinsic width without `minWidth: 26` (only `minHeight: 28`). Keep button labels concise (e.g. `"Add note"` instead of `"Add to comments"`), eliminate redundant text buttons when an icon already represents the action (e.g. removing duplicate `"Research"` text when sparkles icon is present), and ensure floating toolbar frames are sized with adequate buffer.

- **Multi-Line Inline Title Editing with `axis: .vertical`**:
  - **Trap**: Using a single-line `TextField` for inline title editing collapses multi-line titles into a cramped 20pt single-line horizontal scroller, concealing all text beyond the first line and disrupting the card's natural vertical layout.
  - **Rule**: Use `TextField(placeholder, text: $draftText, axis: .vertical)` with `.fixedSize(horizontal: false, vertical: true)` and `.lineLimit(1...15)` matching the non-editing `Text(card.title)`. In `CardNodeView`, assign `.fixedSize(horizontal: false, vertical: true)` and `.frame(maxWidth: .infinity, alignment: .topLeading)` so the editing field preserves the card's natural multi-line layout and line wrapping. Bind `Return` via `.onKeyPress(phases: .down)` to commit the title on plain Return, while allowing `Shift+Return` or `Option+Return` (`.ignored`) to insert newlines.

- **`DragGesture` Hijacking Text Selection in Inline Text Fields**:
  - **Trap**: When a text field is mounted inside a canvas view where background views (e.g. `grid`) or surrounding cards have `DragGesture(minimumDistance: ...)`: clicking and dragging the mouse across text to select characters triggers the background or sibling `DragGesture` after moving just 2-4 points. This causes canvas panning or node movement and aborts mouse tracking in the underlying AppKit field editor (`NSTextView`), completely preventing mouse text selection, copying, and deletion.
  - **Rule**: Whenever title editing is active (`editingCardTitleID != nil`):
    1. Disable background canvas panning: `grid.gesture(panGesture, including: editingCardTitleID == nil ? .all : .none)`.
    2. Disable node dragging on all cards: `nodeDrag(..., including: editingCardTitleID == nil ? .all : .none)`.
    3. Elevate the editing card's `zIndex` to `100` (`isBeingDragged || editingCardTitleID == card.id ? 100 : ...`) so it is always above all other canvas elements.
    4. Remove any `.contentShape(Rectangle())` and `.gesture(...)` on the title header during editing so mouse events pass cleanly to the text field.

- **SwiftUI `CommandGroup(replacing: .undoRedo)` Disabling and Hijacking Active Text Field `UndoManager`**:
  - **Trap**: Replacing `.undoRedo` in SwiftUI with `Button("Undo") { model.undo() }.disabled(!model.canUndo)` hardcodes the undo action to the application's document/database undo stack and binds the enabled state to `model.canUndo`. When a user types in an inline text field (e.g. `InlineTitleEditorView`), `model.canUndo` is `false` (no database action has been committed). macOS intercepts `Command+Z` at the main menu level and swallows the keystroke with an alert beep because the menu item is disabled. Even if enabled, it calls `model.undo()` instead of undoing the typed text in the active `NSTextView`'s `NSCellUndoManager`.
  - **Rule**: In `CommandGroup(replacing: .undoRedo)`, do not statically disable the buttons with `!model.canUndo`. Instead, dynamically inspect `firstResponder` at invocation time:
    ```swift
    Button("Undo") {
        let responder = NSApp.keyWindow?.firstResponder ?? NSApp.mainWindow?.firstResponder
        if let editor = responder as? NSTextView,
           let um = editor.undoManager,
           um !== model.undoManager,
           um.canUndo {
            um.undo()
            editor.didChangeText()
        } else if model.canUndo {
            model.undo()
        }
    }
    .keyboardShortcut("z", modifiers: .command)
    ```
    Apply symmetric handling for `Redo` with `[.command, .shift]`. In the inline editor view itself, also intercept `Command+Z` and `Command+Shift+Z` in `.onKeyPress(phases: .down)` as an extra defense-in-depth layer.

- **`NSTextView.undoManager.undo()` Text Binding Synchronization**:
  - **Trap**: When invoking `editor.undoManager?.undo()` programmatically, `NSTextView` updates its internal text storage, but does not automatically emit text change notifications to its delegate / SwiftUI until `editor.didChangeText()` is explicitly called. Without `didChangeText()`, SwiftUI's `@State draftText` retains the pre-undo string, causing subsequent commits (`commit()`) to re-save the old text.
  - **Rule**: Always call `editor.didChangeText()` immediately following `undoManager?.undo()` or `undoManager?.redo()`, and in `commit()`, read `(NSApp.keyWindow?.firstResponder as? NSTextView)?.string ?? draftText` to ensure the committed value is guaranteed fresh.

- **Text Selection Highlight & Card Header Editing Styling (MarginNote 3 Aligned)**:
  - **Trap**: Replacing the entire card header background with a solid opaque gray during title editing obscures the card's original color completely from edge to edge. Conversely, omitting any editing indicator makes it hard to distinguish which note is being edited.
  - **Rule**:
    1. Retain the card's original accent color on the header (`header.background(cardColors.accent)`).
    2. Place a tight, translucent rounded box around the editing text field (`InlineTitleEditorView`):
       ```swift
       InlineTitleEditorView(...)
           .padding(.horizontal, 4)
           .padding(.vertical, 2.5)
           .background(
               RoundedRectangle(cornerRadius: 3.5)
                   .fill(Color(white: 0.94).opacity(0.55))
           )
       ```
       Balance leading padding (`isEditingTitle ? 5 : 9`) so the text does not jump when toggling edit mode, while leaving the card's original pastel color visible on all edges.
    3. Configure the underlying `NSTextView`'s `selectedTextAttributes` with:
       ```swift
       let darkBlue = NSColor(srgbRed: 55/255.0, green: 88/255.0, blue: 127/255.0, alpha: 1.0)
       editor.selectedTextAttributes = [
           .backgroundColor: darkBlue,
           .foregroundColor: NSColor.white
       ]
       editor.insertionPointColor = darkBlue
       ```
    4. In `applySelectionStyle()`, resolve `firstResponder` by checking `NSApp.keyWindow?.firstResponder ?? NSApp.mainWindow?.firstResponder ?? NSApp.windows.compactMap({ $0.firstResponder as? NSTextView }).first` to ensure reliable execution in headless / unit test runs where `keyWindow` is not active.

- **SwiftUI `HStack` Greedy `Spacer` vs Text Field Wrapping Before Trailing Controls**:
  - **Trap**: Placing a `Spacer(minLength: 4)` between a multi-line `TextField` (`.frame(maxWidth: .infinity)`) and a trailing button (e.g. `Image(systemName: "chevron.right")`) in an `HStack` causes SwiftUI's layout solver to divide remaining width between the flexible text field and the expanding spacer. This steals 40-50pt of width from the text field, causing multi-line titles to wrap unnaturally early and leaving an excessive gap before the chevron.
  - **Rule**: Eliminate the `Spacer` completely. Set `HStack(alignment: .top, spacing: 3)`, apply `.frame(maxWidth: .infinity, alignment: .topLeading)` to both editing and non-editing title views, and set trailing padding to `6pt`. The title text will naturally fill all available horizontal space and wrap cleanly just 3pt to the left of the `>` chevron button, matching MarginNote 3 layout.

- **Split Divider Line Slicing Floating Toolbars Across View Panes**:
  - **Trap**: In multi-pane split workspaces, giving the split divider line an elevated `zIndex` (e.g. `150`) while child pane containers (`mindMapPane`, `pdfPane`) remain at default `zIndex(0)` causes the separator line to render *above* all pane content. When a floating popover (such as the PDF highlight toolbar `PDFPopoverToolbarView`) overflows the pane boundary (e.g. when the PDF pane is narrower than the toolbar width), the vertical divider line slices right through the middle of the toolbar.
  - **Rule**: Elevate the pane that owns the active toolbar above the separator line:
    ```swift
    pdfPane.zIndex((model.activeToolbarOwner == .pdf && !isDraggingSplitDivider) ? 250 : 0)
    mindMapPane.zIndex((model.activeToolbarOwner == .mindMap && !isDraggingSplitDivider) ? 250 : 0)
    ```
    Keep the split divider line at `zIndex(150)`, the draggable split divider pill at `zIndex(300)`, and the live drag indicator line at `zIndex(350)`. Floating toolbars will render seamlessly across pane boundaries without being severed by the separator line.

## Card Decks, MindMap Hierarchy & SRS Review Persistence
- **Decoupled Custom Card Decks vs Topic Study Sets**:
  - **Trap**: In an SRS-driven mindmap application, flashcards can be reviewed either by full study set/topic or organized into dedicated custom card decks (e.g. for exam prep or specific themes). If custom decks are modeled as synthetic `Topic` records or tied to single topics, cards cannot be collected across topics, notes cannot belong to multiple decks, and deleting a deck risks deleting topic cards.
  - **Rule**:
    1. Implement a clean join schema: `card_decks(id, title, created_at, updated_at)` and `deck_cards(deck_id, card_id, created_at, PRIMARY KEY(deck_id, card_id))` with cascading foreign keys to `cards(id)` and `card_decks(id)`.
    2. When adding cards to a deck, ensure an initial `ReviewItem(cardId: cardId, dueDate: Date())` is upserted into `review_items` if not already present, ensuring cards are immediately due for review in the SRS engine.
    3. For recursive mindmap branch addition, compute subtrees using BFS/queue traversing `groupNoteId` (`NoteCard.allDescendants(of:in:)`).
    4. Unify review presentation: Distinguish custom decks from topic sets via `ReviewDeckItem(id, title, dueCount, totalCount, topicId, deckId)`. When launching review for a custom deck, query `cardsForDeck` and `dueCardsForDeck`, populate `activeReviewCards`, and discover matching source documents from `cards.bookMD5` so PDF jump-back remains fully functional.

- **Filter Empty (0-Card) Decks from Review Grid**:
  - **Trap**: Populating review deck items for all topics and custom decks unconditionally floods the Review view with 0-card empty decks (e.g. dozens of imported book documents or topics without note cards), cluttering the UI and confusing the user.
  - **Rule**: Guard `total > 0` in both custom deck and topic study set loops in `reloadLibrary()`. Decks with 0 cards must never appear in the Review grid. When no decks have cards, display the clean empty state with icon `rectangle.stack.badge.play`.

- **MindMap Drag Snapping & Anchored Roots vs Imported Linear Outlines**:
  - **Trap 1**: Calling `insertNearNearestLocation` on drag drop searched for the closest card and synchronously looped over all siblings calling `onMove(c.id, CGPoint(x: 0, y: idx * 100))`. Each `onMove` triggered `reloadStudySet()`, executing multiple SQLite roundtrips and full tree layout recomputations on the main thread, causing severe multi-second UI hangs and random relocations.
  - **Trap 2**: In `TreeLayout`, cards imported from MarginNote have `mindPos = (0.0, y)` representing outline list indices. If all root cards with `mindPos != nil` are treated as anchored roots, large imported topics (e.g. 600+ cards) collapse into a single vertical column 68,000pt tall (`aspect < 0.01`). Conversely, excluding all cards with `bookMD5 != nil` or `startPage != nil` causes user-moved PDF excerpt cards to discard their dropped positions and jump into auto-column coordinates.
  - **Rule**:
    1. Distinguish user-moved / user-placed cards by requiring `pos.x > 0 || (card.bookMD5 == nil && card.startPage == nil)` for anchored roots in `TreeLayout`. Imported linear outline cards (`pos.x <= 0`) flow into balanced auto-column wrap layout.
    2. Implement live 20pt magnetic grid attraction (`TreeLayout.snapToGrid(point, gridSize: 20.0)`) during drag, bounding coordinates to `max(20.0, ...)`.
    3. On drag end: if overlap >= 25% with another card, reparent as child (`onReparent`); if dropped on empty canvas, commit a single `onMove(card.id, snappedOrigin)` call. If a child card is dragged > 320pt away from its parent tree, detach it (`onReparent(card.id, nil)`).

- **Card Deck Selection, Hierarchy Scope & Topic Promotion**:
  - **Trap**: If `AddToDeckSheet` only shows custom decks, users who have not yet created a custom deck see an empty list and cannot add to any existing deck shown on the Review page.
  - **Rule**:
    1. Provide both the floating toolbar button on selected cards and the docked bottom toolbar button with tooltip `Add to Review Deck`.
    2. In `AddToDeckSheet`, display a scrollable radio list of all available decks (custom decks + active topic review sets) showing title and card count capsule badges, alongside a dedicated "Or Create a New Deck" radio row with text field.
    3. If a card has descendants, allow choosing between "This note only (1 card)" and "This note + all N child notes".
    4. If the user chooses an existing topic deck, seamlessly promote it by creating a `card_decks` record with matching ID, backfilling existing topic cards into `deck_cards`, and inserting the new card(s).

- **`VStack` with `.frame(maxHeight:)` Does NOT Clip or Scroll Children**:
  - **Trap**: Applying `.frame(maxHeight: 160)` to a plain `VStack` does not clip child views or provide scrolling. In SwiftUI, the `VStack` measures full height but reports 160pt to the parent layout, which places subsequent views (such as text fields or instruction labels) directly on top of overflowing child views, causing visual collisions and making items unreachable.
  - **Rule**: Always wrap overflowable lists in an explicit `ScrollView(.vertical, showsIndicators: true)` with an explicit `.frame(height: calculatedHeight).clipped()`. Ensure the outer dialog has adequate height (`.frame(width: 480, height: sheetHeight)`) without nested outer scroll containers so trackpad and mouse-wheel events route cleanly to the list.

- **`AddToDeckSheet` New Deck Focus & Mode Synchronization**:
  - **Trap**: Using `.onTapGesture` on or around a SwiftUI `TextField` does not fire when the user clicks into the text field because AppKit's `NSTextField` intercepts and swallows the mouse-down event. If the view relies on `onTapGesture` to switch `deckChoiceMode` from existing deck (0) to new deck (1), `deckChoiceMode` remains 0, and clicking "Add to Deck" silently ignores the user's typed deck name, adding the card to the first existing deck instead.
  - **Rule**: Use `@FocusState private var isNewDeckFieldFocused: Bool` bound to `TextField.focused($isNewDeckFieldFocused)`. Add `.onChange(of: isNewDeckFieldFocused) { if $0 { deckChoiceMode = 1 } }` and `.onChange(of: newDeckTitle) { if !$0.isEmpty { deckChoiceMode = 1 } }`. In `submit()`, prioritize `newDeckTitle` whenever it is non-empty (`!trimmed.isEmpty`), ensuring user-typed deck names are never lost or bypassed. When an existing deck is clicked, explicitly clear `newDeckTitle = ""` and set `isNewDeckFieldFocused = false`.

- **Column Container Grid Model vs Free Anchored Roots in MindMap Canvas**:
  - **Trap**: Splitting root cards into `anchoredRoots` vs `autoRoots` in `TreeLayout` causes moved cards to collide and overlap with existing cards. When a card is moved and assigned `mindPos`, it is removed from `autoRoots` and rendered at its raw `mindPos`. Meanwhile, `autoRoots` reshuffles the remaining cards and places one of them at the exact same location as the moved card. Furthermore, raw MarginNote coordinates (`mind_y = 50,000+`) create massive vertical gaps if treated as absolute canvas coordinates.
  - **Rule**:
    1. Define existing card columns as **Column Containers**. Root cards are partitioned into column containers based on horizontal proximity clustering (`colBaseX`).
    2. Within each column container, cards are stacked strictly sequentially: `nextY = max(colStartY, previousCardSubtreeBottom + verticalSpacing)`. No two cards in the same column can ever collide or overlap.
    3. Columns are spaced horizontally such that `nextColumn.baseX = max(colBaseX, previousColumnMaxX + horizontalSpacing)`. No two columns or their branches can ever collide.
    4. During drag: the card smoothly follows the mouse (`dragLocations[card.id] = mouseLocation`).
    5. On drag end: determine target column container based on `dropCenterX` (or create a new column if dragged beyond the rightmost column), determine insertion slot based on `dropCenterY`, and compute updated non-overlapping positions for all cards in the column in a single SQLite batch transaction (`updateCardPositions`).

- **Mouse-Position-Based "Become Child" vs Bounding Box Overlap in MindMap Dragging**:
  - **Trap**: Using dragged card bounding box intersection (`draggedRect.intersection(otherFrame)`) to detect when a note card should become a child causes unintended reparenting. When a user drags a large or multi-line card past other cards to reorder or move it, the card's rectangular edges intersect adjacent cards even when the user's cursor is in the gutter between columns. The card inadvertently turns into a child note instead of moving into the column container grid.
  - **Rule**:
    1. Base "Become child" detection strictly on **mouse cursor position**, NOT the dragged card's bounding box:
       ```swift
       let mouseCanvasPoint = viewport.screenToCanvas(value.location)
       let overlapTarget = findMouseOverlapTarget(draggedID: card.id, mousePoint: mouseCanvasPoint, frames: staticFrames)
       ```
    2. In `findMouseOverlapTarget`:
       - Recursively exclude all descendants of `draggedID` to prevent cycle generation.
       - Check `layoutResult.visibleCardIDs.contains(other.id)` to ignore folded or culled cards.
       - Test `otherFrame.contains(mousePoint)`. Only if the mouse cursor is strictly inside another card's area does "Become child" trigger.
    3. If the mouse is outside other cards (even if the dragged card's physical shape overlaps other cards), treat the drop as a column container grid movement. The dragged card will snap into the nearest column and push other cards away, guaranteeing zero collisions without accidental reparenting.

- **`NSUndoManager` Notification Trap & Reactive Undo Button State in SwiftUI**:
  - **Trap 1**: `NSUndoManager` does NOT post `.NSUndoManagerDidUndoChange` when an undo action is registered. It only posts `didUndoChangeNotification` when an undo is *executed* (i.e. `undo()` is called). Observing only `didUndoChange` and `didRedoChange` means `AppModel.objectWillChange.send()` is never called when actions are registered, leaving `canUndo` as `false` in SwiftUI views and keeping the Undo toolbar button disabled.
  - **Trap 2**: High-level mutating actions (e.g. `moveCardsBatch`, `reparentCard`, `createChildCard`, `createSiblingCard`, `createFreeNote`, `indent`, `outdent`, `reorder`) that bypass single-card `updateCard` leave the undo manager empty unless explicitly wired.
- **TreeLayout Subtree Traversal & Avoid $O(N^2)$ `allDescendants` Linear Scans in Column Layout**:
  - **Trap**: In `TreeLayout.layout`, determining the rightmost edge of a column container by executing `sortedColumn.flatMap { [$0.id] + $0.allDescendants(in: cards).map(\.id) }` caused an immediate app hang upon opening topics with hundreds of cards (e.g. Ahrens with 685 cards). In `allDescendants`, running `cards.filter { $0.groupNoteId == parentId }` at every BFS node performs a full linear scan over all `NoteCard` structs, causing millions of struct copies and retains on the main thread and pegging CPU at 100%.
  - **Rule**:
    1. In `TreeLayout.layout`, track `currentColumnMaxX = max(currentColumnMaxX, frame.maxX)` directly inside `place(_:depth:baseX:)` as each card and child is positioned. This computes the exact rightmost edge of the column and all its branches in **$O(1)$** per card with zero allocations. Never call `allDescendants` to compute column bounds.
    2. In `NoteCard.allDescendants(of:in:)`, pre-group `let childrenByParent = Dictionary(grouping: cards.filter { $0.groupNoteId != nil }, by: { $0.groupNoteId! })` once upfront. BFS steps then perform $O(1)$ dictionary lookups rather than filtering the entire array, reducing complexity from $O(N^2)$ to $O(N)$.
    3. Keep `NSUndoManager` observers focused on committed state changes (`.NSUndoManagerDidCloseUndoGroup`, `.NSUndoManagerDidUndoChange`, `.NSUndoManagerDidRedoChange`), avoiding `.NSUndoManagerDidOpenUndoGroup` to eliminate spurious invalidation cycles during view evaluation.

- **PDF Navigation, Flashcard Review Jumps & Coordinate Synchronization**:
  - **Trap 1: Continuous Display Mode Lazy Rendering**: In PDFKit with `.singlePageContinuous` or `.continuous` display mode, pages outside the current viewport are not laid out. Calling `pdfView.convert(point, from: page)` for a page without calling `pdfView.go(to: page)` returns `(0, 0)`. The scroll position then clamps to `(0, 0)`, sending the document to the very beginning (page 0). Always call `go(to: page)` first before computing bounds and scrolling to center.
  - **Trap 2: Asynchronous View Layout Post-Sheet Dismissal**: When jumping to PDF from a sheet modal (like `FlashcardReviewView`), `InteractivePDFView` or `StudyWorkspaceView` may be newly mounted or in mid-transition where `clipView.bounds.height <= 10` or `documentView.bounds.height <= 10`. Any scroll calculation performed immediately will evaluate to zero. Detect unlaid out dimensions and re-attempt `scrollToCenter` via `DispatchQueue.main.asyncAfter(deadline: .now() + 0.05)`.
  - **Trap 3: SwiftUI Binding Desynchronization & Reversion to Page 0**: In `PDFReaderView`, if `isNewJump` sets `context.coordinator.lastPageIndex = jumpTarget.pageIndex` but the parent `@Binding var currentPageIndex` remains at 0, subsequent view evaluations (e.g. triggered by selection or toolbar changes) trigger `else if lastPageIndex != currentPageIndex`, immediately navigating `view.go(to: page(at: 0))`. Always synchronize `currentPageIndex = jumpTarget.pageIndex` during `isNewJump`.
  - **Trap 4: Stale `internalJumpTarget` Masking External `jumpTarget`**: In container views, tracking internal navigation with `internalJumpTarget ?? jumpTarget` causes stale internal targets (from TOC or history buttons) to permanently shadow external jump commands. Always prioritize external `jumpTarget ?? internalJumpTarget` and clear `internalJumpTarget = nil` when external `jumpTarget` changes.
  - **Trap 5: Cross-Topic Flashcard Review Jumps & MindMap Focus**: Cards in custom or cross-topic review decks may belong to topics other than `selectedTopicID`. When jumping to PDF:
    1. Switch to the card's topic (`selectTopic(topic)`), ensuring `mindMapCards` and `studyDocuments` load the card.
    2. Switch to the card's document (`switchToDocument(doc)`).
    3. Unfold any folded ancestor cards (`unfoldAncestors(of: card.id)`) so the card is visible in `TreeLayout`.
    4. Set `selectedCardID = card.id`, `activeToolbarOwner = .pdf`, and pass `cardIDToCenter: $model.cardIDToCenter` to `MindMapCanvasView`.
    5. In `MindMapCanvasView`, handle `cardIDToCenter` in `onAppear`, `onChange(of: cardIDToCenter)`, and `onChange(of: proxy.size)` to guarantee centering even across view mounts.
    6. Include a fallback in `activePDFCards` to load `selectedCardID` directly from the database if not yet cached in `mindMapCards` or `documentCards`.

- **Document and MindMap Position Persistence Across Sessions & App Restarts**:
  - **Trap 1: Disk I/O Thrashing & UI Freezes on Active Scrolling / Dragging**:
    High-frequency gesture events (trackpad momentum scrolling in PDFKit, canvas dragging / pinch-to-zoom in SwiftUI) fire up to 120 times per second. Executing synchronous SQLite `UPDATE` statements on every event immediately causes main-thread frame drops, disk thrashing, and beachball hangs.
    - **Rule**: Update in-memory state dictionaries (`documentCurrentPage`, `documentPageOffsets`, `documentMindPan`, `documentMindZoom`, `topicMindPan`, `topicMindZoom`) synchronously for instant 0-latency UI access, and debounce SQLite writes using a 300ms timer (`schedulePositionSave()`).
    - **Rule**: Synchronously commit all pending updates (`flushPendingPositions()`) upon document switching (`switchToDocument`), workspace exit, sidebar tab changes, and application shutdown (`NSApplication.willTerminateNotification`).
  - **Trap 2: Overwriting Saved Reading Positions with Transient Defaults**:
    Upon loading a PDF, `PDFView` initializes at page 0 before layout completes or before programmatic restoration executes. If scroll or page-change observers broadcast immediately during view setup, they will overwrite the user's saved position (e.g. page 15) with page 0.
    - **Rule**: Set an internal guard flag (`isRestoringPosition = true`) during `restorePosition` and release it only after layout settles (`DispatchQueue.main.asyncAfter(deadline: .now() + 0.20)`). Suppress `onPositionChanged` callbacks while `isRestoringPosition` is active.
    - **Rule**: In `insertDocument`, if an existing database document already has non-zero position data (`lastPageIndex > 0 || lastPageOffsetY > 0 || mindPanX != nil`), never overwrite it with default zeros/nils from re-import or discovery scans.
  - **Trap 3: Zoom-Independent PDF Page Offset Calculation**:
    Storing raw viewport scroll offsets (`clipView.bounds.origin.y`) fails because window resizes and display scale factors alter absolute scroll coordinates.
    - **Rule**: Calculate position relative to page coordinate space:
      ```swift
      let topPointInView = NSPoint(x: bounds.midX, y: isFlipped ? bounds.minY + 5 : bounds.maxY - 5)
      let pointInPage = convert(topPointInView, to: page)
      let pageBounds = page.bounds(for: .cropBox)
      let offsetY = max(0, pageBounds.maxY - pointInPage.y)
      ```
      To restore: `PDFDestination(page: page, at: CGPoint(x: pageBounds.minX, y: max(pageBounds.minY, pageBounds.maxY - offsetY)))` and call `view.go(to: dest)`. Because PDF page points are always 72 points/inch in PDF space, this is completely zoom- and window-size independent.
  - **Trap 4: Viewport Restoration Priority in MindMap Canvas**:
    Calling `zoomToFit` on view appear resets the user's canvas position to fit all nodes from the beginning every time a document or notebook is opened.
    - **Rule**: In `MindMapCanvasView.onAppear` and `.onChange(of: selectedTopic?.id)`, respect strict priority:
      1. `cardIDToCenter` (explicit request to focus a card, e.g. review jump)
      2. `initialPanOffset` & `initialZoomScale` (saved session position)
      3. `selectedCardID` (if no saved position exists)
      4. `zoomToFit(nodes:)` (fallback for new notebooks without saved positions)
    - **Rule**: Only emit `onViewportChanged` when `hasInitialFitted == true` to prevent initial default viewport coordinates `(40, 40)` from broadcasting.

- **Startup Default View & Recency Timestamp Preservation**:
  - **Trap: Artificial Timestamp Clobbering on App Launch**:
    Calling document loading logic (`reloadStudySet()`, `switchToDocument()`) during `AppModel.init()` automatically writes `Date()` to SQLite via `updateDocumentLastVisited(...)` and `updateTopicUpdatedAt(...)`. This artificially bumps the first document or hardcoded test topic to the top of the "Recent" sort order on every app restart, completely distorting user recency history.
    - **Rule**: The app must initialize to the Document shelf view by default (`selectedMainTab = .document`, `isInStudyWorkspace = false`).
    - **Rule**: Never call `switchToDocument` or force-open study workspaces in `AppModel.init()`. Wait for explicit user action (e.g. clicking a document in the shelf or selecting a topic in Study notebooks) before loading documents and touching recency timestamps.

- **PDF Annotation Cursor Scaling & Page Edge Clamping**:
  - **Trap: Cursor Bloat & Page Edge Clipping on Small / Zoomed PDFs**:
    PDF page annotations (`PDFAnnotation`) live in PDF page point space. Using fixed point values (e.g. `lineHeight + 14`, `knobSize = 11pt`) causes cursors to scale by `scaleFactor`. In small-page PDFs (such as paperbacks with 327pt page width) where `scaleFactor` is 2.5x to 3x, the cursor becomes massive (60px tall, 28px wide knob). Furthermore, when text is near page margins, unconstrained annotations extend past `page.bounds(for: .cropBox)` and get partially clipped/blocked by the edge of the PDF.
    - **Rule**: Calculate cursor handle dimensions inversely proportional to zoom:
      `let currentScale = max(0.2, self.scaleFactor)`
      `let stemWidth = max(1.0, 2.0 / currentScale)`
      `let stemHeight = lineHeight + (4.0 / currentScale)`
      `let knobSize = max(5.0, 10.0 / currentScale)`
      This ensures handles remain crisp and consistent on screen (~2px stem, ~10px knob) across all document formats and zoom levels.
    - **Rule**: Strictly clamp both stem and knob centers within `page.bounds(for: .cropBox)` with padding:
      `clampedKnobX = max(cropBox.minX + knobSize/2 + pad, min(point.x, cropBox.maxX - knobSize/2 - pad))`
      `clampedKnobY = max(cropBox.minY + knobSize/2 + pad, min(knobY, cropBox.maxY - knobSize/2 - pad))`
      This prevents handles from ever bleeding outside the page cropBox or being clipped by the edge of the PDF.

- **Floating Popover Toolbar Sizing & View Boundary Clamping**:
  - **Trap: Hardcoded Toolbar Dimensions & Unclamped Overflows**:
    Hardcoding popover toolbar width (e.g. 520pt) when actual SwiftUI content requires 610pt causes right-side buttons (e.g. font format, trash) to be clipped inside the hosting view. Positioning without strict boundary clamping allows the toolbar to bleed past the right window edge (blocking scrollbars) or above the top window edge when selections start near the top of the viewport.
    - **Rule**: Always dynamically measure the toolbar's intrinsic size via `NSHostingView(rootView: measureView).fittingSize`.
    - **Rule**: Apply strict 4-edge clamping:
      `let minX: CGFloat = 10.0`
      `let maxX: CGFloat = max(minX, bounds.width - toolbarWidth - 18.0)`
      `x = max(minX, min(x, maxX))`
      `let minY: CGFloat = 8.0`
      `let maxY: CGFloat = max(minY, bounds.height - toolbarHeight - 8.0)`
      `y = max(minY, min(y, maxY))`
      This guarantees the popover toolbar is 100% visible inside the window at all times, with its arrow properly pointing towards the selection knob without distortion.

- **PDFKit Annotation Custom Drawing vs Native Subtypes with Non-Zero CropBox Origins**:
  - **Trap: Custom `draw(with:in:)` Displacements and Crescent Clipping on Non-Zero CropBox PDFs**:
    Overriding `draw(with:in:)` in `PDFAnnotation` subclasses and drawing `context.fillEllipse(in: bounds)` assumes the drawing context aligns directly with annotation bounds. On PDFs with non-zero `cropBox.origin` (such as Screenplay's `cropBox.origin.x = ±4.0`), PDFKit's tile rasterizer passes a clipping rect and CTM shifted by `cropBox.origin`. This causes custom-drawn shapes to be drawn outside their tile clipping rect (appearing as clipped crescents or slivers) and displaced horizontally from native `.square` annotations, making the selection knob appear disconnected from the vertical pole.
    - **Rule**: Prefer PDFKit's native `PDFAnnotationSubtype.circle` with `interiorColor = color` and `border.lineWidth = 0` over overriding `draw(with:in:)`. Native PDFKit drawing handles non-zero cropBox origins, rotation, and sub-pixel alignment seamlessly without custom drawing bugs.
    - **Rule**: Always share the exact same `clampedX` horizontal center for both stem and knob (`clampedX = max(cropBox.minX + halfKnob + pad, min(point.x, cropBox.maxX - halfKnob - pad))`), and overlap in Y (`knobBounds.minY = barBounds.maxY - overlap` for start handle, `knobBounds.maxY = barBounds.minY + overlap` for end handle). Both stem and knob must be clamped within `cropBox.minY + pad ... cropBox.maxY - pad` so neither can be cut off by PDF page edges.

- **Decoupling Real-Time Viewport / Scroll Tracking from Root `@Published` State**:
  - **Trap: Full-Application View Redraw Thrashing During Continuous Scroll / Pan**:
    Storing continuous navigation coordinates (like `documentCurrentPage`, `documentPageOffsets`, `documentMindPan`, `documentMindZoom`) as `@Published` properties on the root `AppModel` causes every scroll notification in `PDFReaderView` and every frame of panning in `MindMapCanvasView` to fire `AppModel.objectWillChange.send()`. This forces the entire application window (all split panes, toolbars, and canvases) to re-evaluate body and layout at 60/120Hz during active scrolling and panning, causing dramatic lag and sluggishness. Spawning unthrottled Swift concurrency `Task`s on every mouse move compounds the issue.
    - **Rule**: In-memory position caches used solely for restoration on document switch or persistence to disk MUST NOT be `@Published`. Store them as plain properties on the model.
    - **Rule**: Throttle high-frequency scroll notifications (e.g. at most once every 250ms during active scrolling + 300ms debounce on rest) and canvas viewport updates (e.g. 200ms debounce). Use lightweight `DispatchWorkItem` on the main queue for debounced saves instead of allocating concurrency `Task`s.
    - **Rule**: Never instantiate ad-hoc `NSHostingView(rootView: ...).fittingSize` during continuous `mouseDragged` events. Cache measured toolbar sizes per mode, hide action toolbars during active dragging, and show them cleanly on `mouseUp`.

- **MindMap Card Selection Outline, Multi-Line Layout & Inset Borders**:
  - **Trap 1: Header / Content Width Mismatch Inside `VStack`**:
    In `CardNodeView`, placing `.frame(maxWidth: .infinity)` *before* `.fixedSize(horizontal: false, vertical: true)` on multi-line title text inside an `HStack` within an unconstrained `VStack` causes SwiftUI's layout solver to size the header view based on ideal wrapped line lengths rather than expanding to the parent card frame (e.g. 220pt or 240pt). When `MindMapCanvasView` centers or pads the card view, a 2-5 pixel strip of `cardBodyBackground` (cream/white) is exposed along the edge of the colored accent header. Inside the blue dashed selection border, this appears as an un-aesthetic "white stroke" or "white edge".
  - **Trap 2: Double-Border Bleed Through Selection Dashes**:
    Drawing `RoundedRectangle.stroke(cardColors.border, lineWidth: 1)` unconditionally under `selectionOverlay` (`RoundedRectangle.strokeBorder(MarginNoteTheme.cursorBlue, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))`) causes the light/pastel card border to stick out 0.5pt outside the card perimeter (since `.stroke` centers on the border while `.strokeBorder` insets inside) and shine through the dash gaps `[4, 3]` as a light/white outline around the selection.
  - **Rule**:
    1. In `CardNodeView`, apply `.fixedSize(horizontal: false, vertical: true)` *before* `.frame(maxWidth: .infinity, alignment: .topLeading)` on multi-line text, and apply `.frame(maxWidth: .infinity, alignment: .topLeading)` to the outer `VStack` so all card sections (accent header, excerpt body, and docked action bar) always expand to 100% of the parent card frame without any background bleed.
    2. When `isSelected == true`, hide the underlying card border: `.stroke(isSelected ? Color.clear : cardColors.border, lineWidth: 1)`. When selected, the card perimeter is cleanly defined exclusively by `selectionOverlay`, eliminating any underlying border bleed through dash gaps or outer perimeter halos.

## MarginNote Database Forensics, Media Storage & Space Optimization
- **CoreData External Storage Duplication & Video Slicing Trap**:
  - **Diagnostic Discovery**: In MarginNote's 83 GB backup, 94.7% of the total size (73.5 GB) is video. MarginNote stores full source lecture videos (45.4 GB) and, when a user excerpts a video note, physically trims and re-encodes a standalone MP4 video clip (averaging 20–50 MB each, totaling 28.18 GB across 1,552 files) inside `MarginNotes.sqlite.files`.
  - **Rule**: Never duplicate video media into database storage. Video note cards must store non-destructive time ranges: `{ bookMD5, start_time: Double, end_time: Double }`. Playback is handled dynamically via `AVPlayer.seek(to:)` with boundary observers. Store only a single lightweight HEIC/JPEG poster frame thumbnail (~30–50 KB) per video card, completely eliminating tens of gigabytes of duplicate media.
- **SQLite Binary Blob Inlining vs Content-Addressable Storage (CAS)**:
  - **Diagnostic Discovery**: MarginNote stores 12,470 uncompressed 32-bit RGBA PNG crops directly inside `ZMEDIA.ZDATA` in the SQLite database, bloating the `.sqlite` file from ~20 MB to 1,190 MB (91.6% blob payload). This invalidates SQLite B-Tree page caches, slows database lock acquisition, and consumes hundreds of megabytes of RAM during queries.
  - **Rule**: Keep SQLite databases strictly relational and blob-free. Store image attachments in a dedicated Content-Addressable Storage directory (`MediaStorage`, keyed by SHA-256 hash). SQLite tables (`cards`) should only store the hash string. This maintains SQLite file size under 20 MB for tens of thousands of cards and yields sub-millisecond query latencies.
- **Image Compression & Hardware Acceleration (HEIC/WebP)**:
  - **Diagnostic Discovery**: Converting raw PNG excerpt crops to HEIC (quality 80–85) achieves 76% to 87% space savings using Apple Silicon's hardware image encoder.
  - **Rule**: Compress all visual excerpt crops to HEIC or WebP. Furthermore, for vector PDF documents that already exist on disk, render text highlight excerpts on the fly directly from the PDF (`PDFPage.draw(with: .cropBox, to:)`) instead of persisting static image crops to disk.
- **SQLite Connections Over Network Shares (SMB / NFS)**:
  - **Trap**: Opening SQLite databases directly on network shares (e.g. `/Volumes/omv/...`) with standard file paths triggers `database is locked` or I/O errors due to SMB lock incompatibilities with SQLite WAL mode.
  - **Rule**: Always open remote or backup SQLite databases in read-only immutable mode using URI filenames: `sqlite3_open_v2("file:/path/to/db.sqlite?immutable=1", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)` (or Python `sqlite3.connect("file:...?immutable=1", uri=True)`).
- **CoreData `ZHIGHLIGHT_PIC` Multi-Segment Selection & Crop Extraction**:
  - **Diagnostic Discovery**: MarginNote visual excerpt cards store their bounding geometry and crop image references inside `ZBOOKNOTE.ZHIGHLIGHT_PIC` as an `NSKeyedArchiver` serialized dictionary containing `paint` (MD5 of crop image in `ZMEDIA.ZDATA`) and `selLst` (array of `{pageNo, rect, imgRect, rotation}`).
  - **Rule**: Deserialize `ZHIGHLIGHT_PIC` using `NSKeyedUnarchiver(forReadingFrom:)` with `requiresSecureCoding = false` (or `PropertyListSerialization`). Extract all selection bounding boxes across pages into multi-segment `HighlightRect` arrays. If `paint` is present, fetch the raw crop data on demand from `ZMEDIA` (avoiding bulk in-memory table loads) and re-encode to hardware-accelerated HEIC in `MediaStorage`, saving 85% disk space.
- **Normalized Video Excerpt Timestamps (`MN3VIDEO`)**:
  - **Diagnostic Discovery**: In MarginNote, video note coordinates are stored in `ZSTARTPOS` and `ZENDPOS` as `MN3VIDEO|<duration>|<fraction>`, where timestamp in seconds equals `duration * fraction`.
  - **Rule**: Parse `ZSTARTPOS` and `ZENDPOS` using the formula `seconds = duration * fraction`. Persist `video_start_time` and `video_end_time` directly as standard `Double` seconds on the card, and generate an on-demand HEIC poster frame via `AVAssetImageGenerator` at `video_start_time` when no thumbnail exists.
- **SQLite FTS5 Full-Text Search Virtual Tables with Content Sync Triggers**:
  - **Rule**: For sub-millisecond full-text search across tens of thousands of cards without duplicating text storage in SQLite, create an external-content FTS5 table:
    ```sql
    CREATE VIRTUAL TABLE IF NOT EXISTS cards_fts USING fts5(
        title, highlight_text, notes_text, tags,
        content='cards', content_rowid='rowid',
        tokenize='unicode61 remove_diacritics 2'
    );
    ```
    Synchronize automatically using SQLite triggers (`cards_ai`, `cards_ad`, `cards_au`) linked to `cards.rowid`, and call `INSERT INTO cards_fts(cards_fts) VALUES('rebuild');` on migration to index pre-existing records.

## Media & Document Handling (Video, Audio & Large Files)
- **Streaming Hashing for Multi-Gigabyte Media**:
  - **Trap**: Using `Data(contentsOf: url)` or `Insecure.MD5.hash(data:)` on video files (e.g. 5–40 GB course recordings) exhausts system RAM and triggers out-of-memory crashes.
  - **Rule**: Always compute file hashes using chunked streaming via `FileHandle` (e.g. 1 MB buffers with `Insecure.MD5`). Cache the computed MD5 in a sidecar `.md5` file next to the media file (`<file>.md5`). When indexing or checking existence, read the sidecar first to achieve sub-millisecond document discovery without I/O thrashing.
- **SwiftUI + AVPlayer Concurrency & State Isolation**:
  - **Trap**: Directly attaching `addPeriodicTimeObserver(..., queue: .main)` inside a SwiftUI `View` struct triggers Swift 6 compiler errors (`main actor-isolated property can not be mutated from a Sendable closure`). Modifying `@State` variables from escaping closures creates race conditions and view tearing.
  - **Rule**: Encapsulate `AVPlayer`, time observation, and playback status into a dedicated `@MainActor final class MediaPlaybackCoordinator: ObservableObject`. The view references the coordinator via `@StateObject`. Use `Task { @MainActor in ... }` or `DispatchQueue.main.async` in the time observer block to update `@Published` variables safely on `@MainActor`.
- **Drag-and-Drop URL Collection with Concurrency Safety**:
  - **Trap**: Mutating a captured `var collectedURLs: [URL]` inside `NSItemProvider.loadObject(ofClass: URL.self)` completion blocks fails Swift 6 strict concurrency checks (`mutation of captured var in concurrently-executing code`).
  - **Rule**: Collect URLs using a thread-safe helper class (`final class URLCollector: @unchecked Sendable` with an `NSLock`) and dispatch the final notification to the main thread via `DispatchGroup.notify(queue: .main)`.
- **Multi-Format Document Pipeline**:
  - **Rule**: Broaden document pickers and drop handlers to accept common video (`mp4`, `mov`, `m4v`, `mkv`, `avi`, `webm`), audio (`mp3`, `m4a`, `wav`, `aac`, `flac`, `aiff`, `caf`), and documents (`pdf`, `epub`). For video and audio documents, `Document.totalPages` stores duration in rounded seconds. In `StudyWorkspaceView`, dynamically branch between `MarginNotePDFContainerView` (for PDFs) and `MediaPlaybackContainerView` (for Video and Audio).
- **AVKit Linkage & Demangling Crash on macOS (`So12AVPlayerViewC`)**:
  - **Trap**: Using SwiftUI's `VideoPlayer(player:)` or AppKit's `AVPlayerView` in a Swift Package Manager executable target without explicitly linking `AVKit.framework` crashes immediately at runtime with `failed to demangle superclass of VideoPlayerView from mangled name 'So12AVPlayerViewC': unknown error`. SPM does not automatically pass `-framework AVKit` unless declared in `linkerSettings`.
  - **Rule**: Always declare `.linkedFramework("AVKit")` in `linkerSettings` for both library and executable targets in `Package.swift`. Additionally, prefer an `NSViewRepresentable` wrapping `AVPlayerView` with `controlsStyle = .none` so that video playback is clean, directly linked, and does not display conflicting built-in overlay controls over custom scrubbers and study toolbars.
- **AppKit `AVPlayerView` Subview Hit-Testing Swallowing Clicks**:
  - **Trap**: Subclassing `AVPlayerView` and overriding `mouseDown(with:)` without overriding `hitTest(_:)` fails to receive single clicks. `AVPlayerView` contains internal private layer and view descendants (`AVPlayerLayer`, `AVPlayerViewPrivate`). When a click occurs, `super.hitTest(point)` returns one of these internal subviews, which consumes the click without forwarding to `mouseDown:` up the responder chain. SwiftUI's `.onTapGesture` on parent or sibling views also fails to trigger because the underlying AppKit view hierarchy intercepts the event.
  - **Rule**: In `CustomAVPlayerView`, override `hitTest(_ point: NSPoint) -> NSView?` to intercept subview hits:
    ```swift
    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard super.hitTest(point) != nil else { return nil }
        return self
    }
    ```
    Returning `self` ensures `mouseDown(with:)` is delivered directly to `CustomAVPlayerView`. Attach an `NSClickGestureRecognizer` as secondary backup, and apply a 100ms timestamp debounce guard in `MediaPlaybackCoordinator.togglePlayPause()` to prevent double toggling.
- **Zero-Friction Single-Button Excerpting**:
  - **Rule**: Avoid interrupting the user's flow with modal sheets or naming prompts when creating video excerpts. Merge "Mark In" and "Mark Out" into a single stateful button. First click sets `markInTime = currentTime`. Second click computes `min(inTime, outTime) ... max(inTime, outTime)`, invokes `onCreateVideoCard(start, end, "")` with an empty title, and resets mark state immediately. The user can rename or edit notes directly on the card in the MindMap later.
- **Filmstrip Timeline Track & Keyframe-Decoded Thumbnails**:
  - **Rule**: In video scrubber tracks, generate filmstrip preview frames asynchronously using `AVAssetImageGenerator` with `maximumSize = CGSize(width: 160, height: 90)` and `requestedTimeToleranceBefore / After = CMTime(seconds: 2.0)`. Tolerances enable fast keyframe/I-frame decoding, allowing 16 preview frames to decode in under 50ms on Apple Silicon with negligible RAM footprint (~3 MB). Overlay note ranges with the card's theme colors (`MarginNoteTheme.cardColors(for: card.colorIndex)`), vertical cap handles (`[ ... ]`), and format ruler ticks using `MediaDocumentHelper.formatRulerTime` (e.g. `3m20s`).
- **Eliminating Double-Click Play/Pause Stutter**:
  - **Trap**: Wiring both `mouseDown(with:)` and an `NSClickGestureRecognizer` (or a parent SwiftUI `.onTapGesture`) to toggle playback causes a single human mouse click (down + up across 100–180ms) to trigger twice if the debounce threshold is shorter than the click duration, causing the video to start and instantly stop.
  - **Rule**: For AppKit view wrappers like `CustomAVPlayerView`, rely exclusively on `NSClickGestureRecognizer` (which fires only once on mouse release) and omit `mouseDown(with:)` callback triggers. Remove duplicate SwiftUI `.onTapGesture` on video containers, and enforce a 300ms debounce guard in `MediaPlaybackCoordinator.togglePlayPause()`.
- **SwiftUI `ZStack` Default Vertical Centering Trap for Borders**:
  - **Trap**: Inside a `ZStack` with `.leading` alignment (where vertical alignment defaults to `.center`), placing `Rectangle().frame(height: 1.5).offset(y: 0)` causes the rectangle to be drawn centered at `height / 2`, slicing a horizontal dividing line right across the vertical center of the track.
  - **Rule**: Always anchor container layouts to `ZStack(alignment: .topLeading)` or use `RoundedRectangle(cornerRadius: ...).strokeBorder(...)` so border strokes map strictly to view perimeters rather than view centers.
- **Card Excerpt Auto-Stop Boundary Playback**:
  - **Rule**: When an excerpt note card is clicked (in the MindMap or on the timeline track), playback should seek to `videoStartTime` and play until `videoEndTime`, automatically pausing at the boundary. Use a high-frequency (50ms) periodic time observer to clamp and pause at `stopAtTime`, and clear the boundary whenever the user manually scrubs or toggles playback.
- **Preventing SwiftUI Text Truncation / Ellipsis in Toolbar Controls**:
  - **Rule**: Rigid fixed button widths (e.g. `frame(width: 32)`) cause numerical strings like `"0.75"` and `"1.25"` to truncate with ellipsis (`"0.75..."`). Always combine horizontal padding (`.padding(.horizontal, 6)`) with `.fixedSize(horizontal: true, vertical: false)` on `Text` views so buttons dynamically fit their exact full text labels without truncation.
- **AVPlayer Rate Mutation & Auto-Play on Document Open**:
  - **Trap**: In AVFoundation, setting `AVPlayer.rate = playbackRate` (where `playbackRate = 1.0`) during setup immediately starts playback. When opening a video document, this causes the video to play unprompted.
  - **Rule**: During player setup/instantiation, always initialize with `newPlayer.rate = 0.0` and `coordinator.isPlaying = false`. Playback must only begin on explicit user action (clicking Play, tapping the video canvas, or selecting a note card).
- **Timeline Playhead Dragging & Note Range Scrubbing**:
  - **Trap**: Checking for containing note cards inside timeline scrubber `DragGesture.onEnded` and calling excerpt playback causes dragging the playhead into a marked note range to unexpectedly start playing.
  - **Rule**: Dragging the playhead must strictly seek to `seekTime` and pause/stop at that exact location. Excerpt range playback should trigger strictly on explicit taps on the note card view or timeline note segment, never on playhead scrub release.
- **Poster Frame Aspect Ratio Preservation & Thumbnail Caching**:
  - **Trap**: Constructing `NSImage(cgImage: cgImg, size: CGSize(width: 148, height: 180))` for a 16:9 video frame forces the `NSImage`'s reported size to a portrait 148:180 ratio. SwiftUI's `.scaledToFit()` then fits this distorted ratio into the card container, squishing horizontal video into a tall portrait rectangle. Furthermore, decoding video frames inside SwiftUI render passes causes scrolling lag.
  - **Rule**: Always construct `NSImage` using the source image's natural pixel dimensions (`NSSize(width: cgImg.width, height: cgImg.height)`). Display inside `DocumentCardView` using `.resizable().aspectRatio(contentMode: .fit)` within a dark letterboxed container (`Color(red: 0.13, green: 0.14, blue: 0.17)`). Cache thumbnails using `@MainActor private let coverThumbnailCache = NSCache<NSString, NSImage>()`.
- **Document Folder Relational Persistence Safety**:
  - **Rule**: When implementing folder hierarchies with `document_folders` and nullable `folder_id` on `documents`, folder deletion must never cascade-delete documents. Always execute `UPDATE documents SET folder_id = NULL WHERE folder_id = ?` prior to deleting the folder row, safely moving all contained documents back to root.
- **Batched Note Card Count Retrieval & Zero-Count Badge Suppression**:
  - **Trap**: Querying card counts for each document in a loop ($N$ queries) causes sluggish shelf reloads on large libraries. Additionally, showing a "0" badge clutters the document grid.
  - **Rule**: Retrieve card counts for all documents in a single batched query: `SELECT book_md5, count(*) FROM cards WHERE book_md5 != '' AND is_deleted = 0 GROUP BY book_md5`. In the UI (`DocumentCardView`), guard badge rendering strictly on `if cardCount > 0`, displaying the badge only when notes exist.
- **Unified Document Thumbnail Visual Language**:
  - **Rule**: Standardize video, audio, and PDF document card thumbnails with the same warm paper fill (`Color(red: 0.93, green: 0.91, blue: 0.86)`). When video or audio documents lack a poster frame, display a clean centered media icon with muted secondary styling, avoiding high-contrast black boxes in the document shelf.
- **Browser-Style Multi-Document Study Tabs & Mixed Media Navigation**:
  - **Rule**: In multi-document study topics, host a browser-style `DocumentTabBarView` atop the media pane. By switching `model.activeDocument` without unmounting `StudyWorkspaceView`, the right pane dynamically switches between `MarginNotePDFContainerView` and `MediaPlaybackContainerView` while keeping the MindMap canvas and active topic intact. When navigating to a card from another document, auto-attach missing documents to the topic, switch the tab, and dispatch seeking/page navigation seamlessly.
- **AppKit/SwiftUI `Menu` Horizontal Expansion in Toolbars**:
  - **Trap**: Using `Menu { ... } label: { ... }` with `.menuStyle(.borderlessButton)` inside an `HStack` without layout constraints causes the underlying AppKit button to expand horizontally to fill all available proposed space, creating massive, stretched buttons.
  - **Rule**: Always apply `.fixedSize()` to `Menu` views in toolbars, headers, and popovers so the button strictly hugs its content dimensions.
- **Nested Button Tap Bubbling in Document & Folder Cards**:
  - **Trap**: Nesting a secondary button (such as a `"..."` more actions button) inside a parent `Button` that wraps the entire card causes clicks on the secondary button to bubble up and trigger the card's open or selection action.
  - **Rule**: Decouple the card into two sibling components within the vertical container: a primary `Button` wrapping the cover and title, and an independent sibling `HStack` for bottom metadata and the `"..."` action popover button.
- **AppKit `Menu` Inset & Misalignment Trap in Vertical Popovers**:
  - **Trap**: Mixing `Menu { ... } label: { ... }` with plain `Button`s inside a vertical popover card (e.g. `DocumentActionCardView`) causes severe alignment discrepancies. On macOS, `Menu` with `.menuStyle(.borderlessButton)` renders as an AppKit `NSPopUpButton` cell. The cell strips child view horizontal padding, injects an unwanted downward chevron arrow next to the label, and shifts the row's icon ~10pt to the left, breaking vertical guide alignment with sibling `.buttonStyle(.plain)` buttons.
  - **Rule**: Never use SwiftUI `Menu` inside custom vertical popovers or menus when aiming for uniform vertical alignment with other buttons. Instead, render a standard `Button` with `.buttonStyle(.plain)` displaying a trailing `chevron.right`, and use local state navigation (`@State private var showingMoveDestinations: Bool = false`) with an interactive back button (`← Move to`). Because every row is a plain `Button` with identical padding (`.padding(.horizontal, 10)`), spacing (`8pt`), and icon framing (`.frame(width: 16)`), icons and text remain strictly aligned along the exact same vertical guide.
- **Nested Folder Relational Integrity & Cycle Prevention**:
  - **Trap**: Allowing arbitrary re-parenting of folders without ancestor traversal can create circular reference cycles (e.g. Folder A moved into Folder B, which is inside Folder A), making the folder tree unreachable or triggering infinite recursion during tree walks.
  - **Rule**: When offering destination targets in "Move to…" (or executing folder reparenting in the database), always validate candidate destinations with an ancestor walk: `candidate.id != folder.id && !isDescendant(candidateChildID: candidate.id, of: folder.id)`. When deleting a folder, safely re-parent all child documents and immediate child folders to the deleted folder's `parentId` (or `NULL` if at root), never cascade-deleting child content.
- **Study Notebook Highlight Isolation vs Global Document Cards**:
  - **Trap**: Merging library-wide document cards (`documentCards = database.cardsForDocument(md5:)`) into active reader cards unconditionally caused all previous highlights across the entire library to appear when studying in a newly created or empty notebook.
  - **Rule**: When inside an active study workspace (`selectedTopicID != nil`), document highlights must be strictly scoped to `mindMapCards.filter { ... card.bookMD5 == activeDoc.md5 }`, ensuring newly chosen notebooks start completely clean and notes from other notebooks remain isolated.
- **Cross-Tab Cursor and Handle Annotation Bleed**:
  - **Trap**: Failing to clear selection state (`selectedCardID`, `jumpTarget`) and annotation handles upon switching document tabs caused PDF page annotations (cursor stems and knobs) from the previous document to render on the newly opened tab.
  - **Rule**: On tab switch (`activeDocument?.id != document.id`), reset `selectedCardID = nil` and `jumpTarget = nil`. In `InteractivePDFView.updateNSView`, when `view.document !== manager.document`, immediately call `clearHandles()`, `clearPendingSelection()`, `selectedSegmentID = nil`, and `hideToolbar()`. In `applyActiveSelection`, guard card matching with `card.bookMD5 == manager.md5` and explicitly call `clearHandles()` in the else branch.
- **Document Tab Bar Positioning Under Top Toolbar**:
  - **Trap**: Placing `DocumentTabBarView` outside the PDF pane in the outer workspace `VStack` positioned tabs above the primary annotation toolbar (`topToolbarHeight`), breaking horizontal alignment with the MindMap header and violating MarginNote 3 layout.
  - **Rule**: Render document tabs as Row 2 directly inside `MarginNotePDFContainerView` and `MediaPlaybackContainerView` beneath Row 1's top toolbar, ensuring top toolbars align horizontally across split panes while tabs sit directly above document canvas.
- **Bottom Floating Toolbar Menu Border Bleed & Hierarchical Move-To Popovers**:
  - **Trap**: Anchoring an AppKit `Menu` on a floating toolbar near the window's bottom edge causes the popup menu to expand downwards and bleed past the bottom window border. Furthermore, displaying destination folders without hierarchical sorting/indentation in individual card popovers prevents users from recognizing nested folder structures.
  - **Rule**: Use a button with `.popover(isPresented: ..., arrowEdge: .top)` on bottom-docked toolbars so menus pop upwards and remain safely inside window bounds. In action card popovers, sort folders hierarchically (`hierarchicallySortedFolders`) and prefix nested items with indentation and `↳ ` matching tree depth.
- **PDF Handle Knob and Stem Sizing in Page Coordinates vs View Scale Factor**:
  - **Trap**: Calculating PDF page annotation dimensions (stem width, stem height, knob radius) as `10.0 / scaleFactor` where `scaleFactor` can be 0.0 or uninitialized before the view's layout completes or during document tab switches. Clamping with `max(0.2, scaleFactor)` causes `10.0 / 0.2 = 50.0` points, resulting in massive, multi-line cursor knobs permanently attached to the PDF page annotations.
  - **Rule**: In `InteractivePDFView.handleDimensions(for:scale:)`, sanitize `scale`: if `scale <= 0.05` or `isNaN` or `isInfinite`, fall back to 1.0. Clamp effective scale to `[0.8, 5.0]` so knobs never exceed 12.0 points and never drop below 4.0 points (`knobSize = max(4.0, min(12.0, 10.0 / effectiveScale))`). This guarantees that cursor knobs never blow up even before view layout finishes.
- **Preserving Selection and Jump Target During Programmatic Card Jumps**:
  - **Trap**: Unconditionally resetting `selectedCardID = nil` and `jumpTarget = nil` inside `switchToDocument(doc)` cancels card focus and jump navigation when a user clicks a note card belonging to a different document tab in multi-document study mode, requiring a second click to focus the card.
  - **Rule**: Parameterize document switching with `switchToDocument(_ document: Document, clearSelection: Bool = true)`. Callers deliberately navigating to a note card pass `clearSelection: false` and explicitly restore `selectedCardID = card.id`, allowing the first click to switch tabs and immediately focus the selected note card.
- **Cascading Relational Deletion of Study Topics**:
  - **Trap**: Deleting from non-existent tables (such as `topic_documents` or `links`) causes SQLite errors that abort topic deletion or cause silent failures inside `try? deleteTopic(id:)`.
  - **Rule**: Ensure `Database.deleteTopic(id:)` queries strictly target valid tables in schema: delete from `deck_cards WHERE card_id IN (SELECT id FROM cards WHERE topic_id = ?)`, `review_items WHERE card_id IN (SELECT id FROM cards WHERE topic_id = ?)`, `card_links WHERE topic_id = ?`, `cards WHERE topic_id = ?`, and finally `topics WHERE id = ?`.
- **Search Bar Auto-Focus Lifecycle via SwiftUI `@FocusState`**:
  - **Trap**: When revealing a search bar or search overlay via button click, users expect to immediately type their search query. Without automatic first-responder focus, the user must click the search icon and then make an unnecessary second click inside the text field to begin typing.
  - **Rule**: Bind `@FocusState private var isSearchFieldFocused: Bool` to the `TextField` with `.focused($isSearchFieldFocused)`. In `.onAppear` (and `.onChange(of: isSearchPresented)` if dynamically toggled), trigger `DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { isSearchFieldFocused = true }`. Wire `.onExitCommand` to clear text or dismiss search cleanly when pressing Escape.
- **Add Existing Documents vs Import Document in Study Notebooks**:
  - **Trap**: In study workspaces, having the `+` button in the document tab bar and the "+ Add Document…" button in the Manage sheet trigger `NSOpenPanel` (import from disk) causes duplicate imports and prevents users from assembling existing library documents into multi-document study sets.
  - **Rule**: Decouple "Add Existing Document" from "Import Document". The `+` button on the tab bar and the primary "+ Add Document…" button in Manage should present an in-library document selector (`StudyDocumentManagementSheet` with mode `.addExisting`) listing documents in the user's database that are not yet attached to the notebook, equipped with an auto-focused search filter and type badges. Provide a distinct "Import Document…" button (`square.and.arrow.down`) for opening `NSOpenPanel` to import new files from disk.
- **Multi-Document Tab Dynamic Width, Auto-Scrolling, and Dropdown Switcher**:
  - **Trap**: Hardcoding a wide tab width (e.g. `maxWidth: 170`) in a horizontal `ScrollView` hides tabs when 4+ documents are added to a notebook. Standard mouse users cannot scroll horizontally, and off-screen tabs remain invisible and unclickable without an overflow mechanism.
  - **Rule**: Dynamically compute `tabTitleMaxWidth` based on `documents.count` (scaling from 160pt down to 60pt for 8+ documents). Wrap the tabs in `ScrollViewReader` and scroll to `activeDocument.id` with `anchor: .center` on appear and active document change. Provide a compact dropdown menu button (`chevron.down`) next to the tabs listing all study documents with active checkmarks and type icons, ensuring 1-click access to every document regardless of tab count.
- **Selection Cursor Rendering: View-Space Overlay vs PDFAnnotation Rendering (`SelectionCursorOverlayView`)**:
  - **Trap**:
    1. **PDFKit Text Layer Z-Ordering**: In macOS PDFKit, custom `PDFAnnotation.draw(with:in:)` calls are rendered during internal page tile rasterization *underneath* vector text glyphs, OCR layers, and selection highlights. No matter the array order in `page.annotations`, PDF text is always drawn over the annotation, visibly cutting or obscuring the handle stem and knob.
    2. **PDFAnnotation Tile Clipping**: PDFKit clips `draw(with:in:)` to the annotation's bounding box and tile margins. When dragging or scaling, subpixel tile offsets chop circular knobs into semicircles.
    3. **Ghost Cursors**: Rendering cursors in both an overlay and `PDFAnnotation.draw` creates double/ghost cursors with slight subpixel offset artifacts.
  - **Rule**:
    - **Native AppKit Overlay (`SelectionCursorOverlayView`)**: Selection cursor handles must be rendered exclusively in view space by a dedicated `SelectionCursorOverlayView` added to `InteractivePDFView` with `addSubview(overlay, positioned: .above, relativeTo: nil)`.
    - **Event Transparency**: Override `hitTest(_:) -> NSView?` to return `nil` so the overlay never intercepts mouse clicks, selections, or drag gestures.
    - **Coordinate Mapping**: Map page coordinates to view space via `pdfView.convert(point, from: page)`.
    - **Coaxial Stem & Knob**: Group the vertical stem (width: 2.0pt, height: 1.2x line height) and circular knob (radius: 3.2pt) into a single CoreGraphics path sharing the exact same `stemCenterX`. Start knob is pinned to the top tip of the stem; end knob is pinned to the bottom tip of the stem.
    - **No-Op `CursorHandleAnnotation.draw`**: Keep `CursorHandleAnnotation` registered on `page.annotations` purely for unit test metadata assertions, but make its `draw(with:in:)` a complete no-op.
- **MarginNote Sandbox Container Thumbnail Loading (`DocumentShelfView`)**:
  - **Trap**: Hardcoding `!path.contains("Library/Containers/QReader.MarginStudyMac")` in document card thumbnail loaders blocks cover image generation for all documents stored in MarginNote's application sandbox, causing document shelf cards to display empty grey vector placeholders instead of book covers.
  - **Rule**: Remove any path-based container exclusions in thumbnail loaders. As long as `FileManager.default.fileExists(atPath: path)` is true, allow `MediaDocumentHelper` and asynchronous `PDFDocument` loaders to generate cover thumbnails regardless of whether the document resides in `Application Support` or `Library/Containers`.
- **EPUB Document Support & High-Performance Conversion Pipeline (`EPUBConverter`)**:
  - **Trap**: EPUB files are reflowable XHTML packages that lack fixed 2D page geometries. Directly rendering EPUB in dynamic WebViews breaks spatial highlight persistence, mindmap card jump targets, and multi-document study tabs across window resizing.
  - **Rule**: Convert incoming `.epub` files into high-fidelity paginated PDF documents on import using `EPUBConverter`:
    - **Two-Tier Engine**: Convert with PyMuPDF (`pymupdf.open(epub).convert_to_pdf()`) for sub-second (~0.5s) rendering preserving Table of Contents, metadata, and vector text; fall back to Calibre's `ebook-convert` if Python is unavailable.
    - **Caching & Identity**: Cache converted PDFs in `Application Support/MarginGraph/Documents/<md5>.pdf` keyed by the EPUB's unique content hash. Subsequent opens load the cached PDF instantly in 0ms.
    - **Full Feature Parity**: Set `documentType = "epub"` and `filePath` to the converted PDF. This automatically equips EPUB documents with 100% of PDF capabilities: precision text selection, selection cursors, mindmap card excerpting, jump targets, table of contents, bookmarks, search, and multi-document study tabs.
- **PDF Multi-Line Block Excerpt Expansion to Individual Line Rects**:
  - **Trap**: MarginNote 3/4 exports and database imports often store multi-line text excerpts as a single 2D bounding box `CGRect(x, y, width, height)` with `height > 20pt` (often 80-160pt encompassing an entire paragraph). When installing handles or highlights, taking `lineRects.first` and `lineRects.last` on this single bounding box places BOTH cursors at `y = rect.y + rect.height / 2` (floating halfway down the paragraph on an arbitrary line in the middle) rather than at the start of the first line and the end of the last line. Furthermore, passing `height = 160pt` as line height causes cursors and knobs to expand or clamp to their maximum allowed bounds.
  - **Rule**: Always expand block bounding boxes with `PDFHighlightResolver.expandBlockRectsIfNeeded(_ rects:in document:)`. Whenever a rect has `height > 20pt`, query `page.selection(for: box.insetBy(dx: -2, dy: -2)).selectionsByLine()` to extract the exact physical line rects in reading order. If the rect cannot be broken into lines (e.g. image crop), `endpoint(for:start:)` must place the start handle at the top-left of the box (`y = rect.y + rect.height - lineHeight/2`) and the end handle at the bottom-right (`y = rect.y + lineHeight/2`), clamping `lineHeight` to `min(rect.height, 22.0)`.
- **Reading Order Sorting Invariant Across PDF Coordinates**:
  - **Trap**: In PDFKit coordinates, `(0, 0)` is at the bottom-left of the page. Sorting lines by `y` ascending places the bottom-most line first and the top-most line last (inverting reading order). Moreover, combining lines across pages without sorting produces inverted or arbitrary cursor endpoints.
  - **Rule**: Standardize reading order sorting via `PDFHighlightResolver.sortInReadingOrder(_ rects:)`:
    - Sort by `page` ascending first.
    - For the same page, if `abs(r1.y - r2.y) > 4.0`, sort by `r1.y > r2.y` (higher `y` appears earlier on the page from top to bottom).
    - For lines at the same vertical position (`abs(r1.y - r2.y) <= 4.0`), sort by `r1.x < r2.x` (left to right).
    Start handle must attach to `sorted.first` (left edge, top line) and end handle must attach to `sorted.last` (right edge, bottom line).
- **Multi-Document Study Notebook Card MD5 Isolation & Tab Switching**:
  - **Trap**: In multi-document study topics, cards from Doc A and Doc B share the mind map. If `applyActiveSelection` does not verify `card.bookMD5 == manager.md5` with case insensitivity, or if `activePDFCards` uses case-sensitive comparison, selecting a note card for Doc A while viewing Doc B will attempt to resolve page indices and highlight coordinates on Doc B, generating misplaced cursors on unrelated pages.
  - **Rule**: Always normalize MD5 strings to lowercase (`bmd5.lowercased() == activeDoc.md5.lowercased() || bmd5.hasPrefix(...) || activeDoc.hasPrefix(...)`). In `applyActiveSelection`, if `!isActive(card: selected)`, immediately clear handles and hide the toolbar.
- **Asynchronous PDFKit Parsing & Thumbnail Generation in SwiftUI Views**:
  - **Trap**: Initializing `PDFDocument(url:)` or rasterizing page images synchronously inside a SwiftUI view's `body` (e.g. `DocumentCardView`). If any file on disk is locked, requires FileCoordination, or is located on an external/cloud volume, the AppKit main thread blocks in kernel `__open`, freezing the entire application and preventing the main window from ever appearing.
  - **Rule**: Never invoke synchronous `PDFDocument(url:)` inside SwiftUI view bodies. Use an asynchronous image loader off the main thread (`DispatchQueue.global(qos: .utility)`), cache extracted thumbnails in memory (`NSCache` or thread-safe dictionary), and immediately render an instantaneous vector placeholder in `body` while thumbnails generate asynchronously.
- **CLI-Launched Bare Binary Window Server Activation Policy**:
  - **Trap**: When a Swift executable without an `.app` bundle wrapper is launched directly from the CLI or automated test harness (`.build/arm64-apple-macosx/debug/MarginGraphApp`), macOS defaults the process activation policy to accessory or prohibited. The process starts, runs in the background, but never creates an entry in WindowServer or displays its `WindowGroup` window.
  - **Rule**: Always invoke `NSApplication.shared.setActivationPolicy(.regular)` inside the SwiftUI `App.init()` before the application finishes launching. This forces macOS to register the process as a standard GUI app with an active window and dock tile regardless of launch origin.
- **MindMap Search Architecture & Multi-Scope Note Filtering (`MindMapSearchMatcher`, `MindMapSearchBarView`)**:
  - **Trap**: Searching only card titles leaves users unable to locate notes created from PDF excerpts or comments where the title is blank or generic. Completely removing non-matching cards from the canvas tree destroys the topological structure of the mindmap, severing branches, parent-child connectors, and spatial memory.
  - **Rule**:
    1. **Multi-Scope Search Matcher (`MindMapSearchMatcher`)**: Support `.all` (Title & Content), `.title` (Title Only), and `.content` (Content Only). Perform case-insensitive localized searches across `title`, `notesText`, `highlightText`, `excerptSegments`, and `tags`, with automatic fallback to `highlightText` for untitled cards.
    2. **Single Workspace Toolbar Search Trigger & Keyboard Navigation**: Provide the search entry point on the top workspace header toolbar (`StudyWorkspaceHeaderView`) and via `⌘F` (`CommandMenu("Find")`). Avoid duplicate floating search pills on the canvas to prevent visual clutter and card occlusion.
    3. **Non-Destructive Graph Highlighting & Dimming**: Maintain graph integrity by retaining all nodes on canvas: dim non-matching cards to `opacity: 0.28` and non-matching connectors to `opacity: 0.18`. Frame matching cards with an accent blue ring (`lineWidth: 2.2`), and frame the active match with a prominent gold/amber halo (`lineWidth: 3.5`, orange shadow).
    4. **Debounced Viewport Navigation**: Debounce search jumps by 200ms (`scheduleMindMapSearchJump`) during text input to prevent canvas thrashing. Support `Enter` / `Shift+Enter`, stepper buttons, and a results popover (`list.bullet`) to cycle through matches, auto-centering the viewport (`cardIDToCenter`) and selecting the card (`model.select(card:)`) so the companion PDF reader simultaneously jumps to the referenced page.
    5. **Opaque Floating Header Pill**: The floating canvas layer selector (`mainMindMapHeader`) positioned over draggable graph nodes must use a fully opaque background with subtle borders (`Color(white: 0.99)`, 0.5pt stroke, shadow) rather than ultra-thin translucent materials to prevent underlying card text from bleeding through.
- **MindMap Card Multi-Paragraph Height Estimation and Docked Action Bar Spacing (`TreeLayout.estimatedCardHeight`, `MindMapCanvasView`)**:
  - **Trap**:
    1. **Naive Character Count Text Height Underestimation**: Estimating card height using character division (e.g. `(chars + 34) / 35 * 16.5`) assumes continuous single-line text flow. Multi-paragraph notes with blank lines (`\n\n`), markdown lists, or short lines incur full line heights (~17pt each) with zero character count contribution, underestimating note card height by 30–60+ pt. Downstream cards placed by column packing or child/sibling placement algorithms then overlap or touch edge-to-edge (0pt separation).
    2. **Docked Bottom Action Bar Expansion & Z-Index Obscuration**: When a card is selected in `MindMapCanvasView`, an action bar is docked at its bottom edge, expanding the card downwards by ~28pt. If canvas vertical spacing between cards is $\le 28\text{pt}$ (e.g. default `28.0` or `36.0`), or if sibling cards share default `zIndex(1)`, selecting the upper card causes its bottom toolbar to either collide with or be obscured underneath the card below it in the column.
  - **Rule**:
    1. **Native Text Layout Measurement with `NSAttributedString.boundingRect`**: In `TreeLayout.estimatedCardHeight`, measure text using native font geometry (`boundingRect(with:options:attributes:)` with `[.usesLineFragmentOrigin, .usesFontLeading]`, font size 11.5pt regular/bold, line spacing 2). In headless/non-AppKit environments, split on `\n` to measure explicit lines and paragraph breaks accurately.
    2. **Standard 56pt Vertical Spacing Margin**: Configure `TreeLayoutConfiguration.verticalSpacing = 56.0` and standardize all canvas column re-packing and dynamic card creation offsets on `TreeLayout.estimatedCardHeight(for: card, width: 220) + 56.0`. This guarantees clean 56pt physical separation between unselected cards and maintains a generous 28pt buffer ($56 - 28 = 28\text{pt}$) when the upper card is selected and expands downward with its 28pt docked action bar.
    3. **Selected Card Z-Index Elevation**: In `MindMapCanvasView`, assign `.zIndex(isCardSelected ? 60 : (isHovered ? 40 : 1))` so that when any card is selected, its entire container and docked bottom action bar render strictly above lower cards in the same column, guaranteeing complete visibility and hit-test accessibility.
- **Universal Native Zero-Dependency EBook Conversion Engine (`EBookConverter`)**:
  - **Trap**: Relying on external tools like Calibre (`ebook-convert`, which is >1.0 GB and GPLv3-licensed), Python (`pymupdf`), or Pandoc forces end-users to install third-party developer toolchains before opening ebooks, comics, or documents. On clean macOS systems without those packages, imports fail. Furthermore, converting diverse formats to PDF can strip document type identity, reducing all shelf badges to generic "PDF".
  - **Rule**:
    1. **Zero-Dependency Native Pipeline Across All Formats**: Support 16+ common ebook and document formats natively using built-in macOS frameworks (WebKit, PDFKit, AppKit, `/usr/bin/unzip`):
       - **EPUB**: Built-in `/usr/bin/unzip`, OPF/NCX XML parsing, and WebKit printing with interactive `PDFOutline` TOC.
       - **CBZ / CBR**: Unpack images using `/usr/bin/unzip`, naturally sort page names, and assemble a vector `PDFDocument` by appending `PDFPage(image:)` instances.
       - **FB2 / ZFB2**: Pure Swift `XMLParser` parsing metadata, hierarchical sections, and base64 embedded binary images (`<binary id="...">`) converted into styled HTML -> WebKit vector PDF.
       - **MOBI / PRC**: Pure Swift PalmDOC LZ77 decompressor (`decompressPalmDOC`) parsing PDB record offset headers and decoding LZ77 compressed byte streams into raw HTML -> WebKit vector PDF without external binaries.
       - **TXT / Text**: Multi-encoding fallback detection (UTF-8, UTF-16, Latin1, MacRoman), regex chapter detection (`Chapter \d+`, `Book \d+`, `第...章`), and styled typographic HTML -> WebKit vector PDF with `PDFOutline` TOC.
       - **Markdown (MD)**: Lightweight native Markdown to HTML converter supporting headers, bold/italic, code blocks, blockquotes, lists, and horizontal rules -> WebKit vector PDF.
       - **RTF / RTFD**: Native `NSAttributedString` parsing -> styled HTML -> WebKit vector PDF.
       - **HTML / WebArchive**: Direct WebKit rendering into vector PDF.
    2. **Format Identity Sidecars (`<md5>.format`)**: Converted files are stored in persistent storage as `<md5>.pdf`. Storing an adjacent `<md5>.format` file allows `Database.syncAvailableDocuments()` and the Document Shelf / Tab Bar to restore original document types (`comic`, `fb2`, `mobi`, `text`, `markdown`, `rtf`, `html`, `epub`) without losing format identity.
    3. **Thread-Safe WebKit Invocation**: Execute WebKit operations on `MainActor.assumeIsolated` and bridge outputs synchronously via `ThreadSafeBox` to ensure compatibility with background import queues.
    4. **Full Feature Parity**: By standardizing all ebook formats into vector PDFs on import, every ebook format inherits 100% of MarginGraph capabilities: precision text selection, selection cursor handles, mindmap card excerpting, jump targets, table of contents, bookmarks, search, and multi-document study tabs.
- **WebKit Local File Navigation & Symlink Resolution Trap in Headless Converters (`WebKitChapterRenderer`)**:
  - **Trap**:
    1. On macOS, `/var/folders/...` is a symbolic link pointing to `/private/var/folders/...`. When file enumerators (`FileManager.default.enumerator`) discover files inside temporary directories, they return canonical paths starting with `/private/var/folders/...`. If `webView.loadFileURL(fileURL, allowingReadAccessTo: tempDir)` is called with an unresolved `tempDir` (`/var/folders/...`), WebKit considers the file outside the permitted sandbox directory and immediately aborts navigation via `didFailProvisionalNavigation`.
    2. In `WKNavigationDelegate`, routing `didFail` or `didFailProvisionalNavigation` to the standard success completion handler that invokes `evaluateJavaScript(...)` causes silent deadlocks: because the web process never loaded a document, JavaScript evaluation errors out or never yields, and `webView.createPDF(...)` is never called. Any synchronous waiting loop (`runOnMainThread`) then stalls until the global timeout.
  - **Rule**:
    1. Always resolve symlinks on both target file and read access directory before invoking WebKit: `url.resolvingSymlinksInPath()` and `readAccessURL.resolvingSymlinksInPath()`.
    2. In `WKNavigationDelegate`, immediately dispatch `.failure(error)` on `didFail` and `didFailProvisionalNavigation`. Never attempt to evaluate JavaScript or create PDFs on an unnavigated web view.
    3. Guard all asynchronous WebKit render calls with a one-shot completion handler (`isCompleted` flag) and a 10.0-second safety timeout (`DispatchWorkItem`) to guarantee that `runOnMainThread` never deadlocks.
- **Comprehensive Zero-Dependency Format Expansion Architecture (`EBookConverter`)**:
  - **Rule**: Expand native format support to cover all common technical, office, and legacy document types without external package dependencies:
    - **Office & OpenDocument (`docx`, `doc`, `odt`)**: Leverage system `/usr/bin/textutil -convert html` and AppKit `NSAttributedString` to extract typography, tables, and formatting into vector PDFs.
    - **Comic Archives (`cbt`, `cbz`, `cbr`)**: Leverage built-in `/usr/bin/tar` (for `.cbt`) alongside `/usr/bin/unzip`, extracting images and ordering pages naturally (`localizedStandardCompare`) into multi-page `PDFDocument`s.
    - **Kindle & Palm Documents (`azw`, `azw3`, `kf8`, `pdb`)**: Parse Palm Database (`PDB`) headers, record lists, and PalmDOC LZ77 decompression streams. For KF8/AZW3, parse the mobi-header boundaries to extract HTML5 content, CSS styles, and chapter breaks (`<mbp:pagebreak/>`).
    - **Compiled HTML Help (`chm`)**: Detect `ITSF` magic bytes, extract embedded HTML documentation chapters directly using native stream regex parsing (with `extract_chmLib`/`7z` as transparent accelerators when present), wrap extracted chunks in standard HTML5 with UTF-8 meta charset, and render with hierarchical table of contents.
    - **Scanned DjVu Documents (`djvu`, `djv`)**: Detect `AT&T` / `FORM DJVU` magic bytes, extract OCR text layers from compressed `TXTz` (zlib) and `TX3t` chunks, and format extracted OCR text into readable vector pages (with `ddjvu` acceleration if available).
    - **Academic & Technical Markup (`tex`, `latex`, `adoc`, `asciidoc`, `org`, `rst`)**: Implement pure Swift AST parsers that extract document titles, authors, hierarchical section headers (`\section`, `==`, `*`, underlines), styled code blocks, quote callouts, and mathematical formulas into modern, beautifully styled academic typography converted to vector PDF via WebKit with full `PDFOutline` bookmarks.
- **Thumbnail Generation for Converted EBooks & Format Identity Sidecars (`docType` vs `.pdf` extension)**:
  - **Trap**: When documents are converted by `EBookConverter` into persistent PDFs, their shelf metadata is assigned `docType = "epub"`, `"docx"`, `"odt"`, `"comic"`, etc., but the physical file on disk is `<md5>.pdf`. In `DocumentShelfView.generateCoverThumbnail`, checking `else if docType == "pdf" || MediaDocumentHelper.isEBook(url: url)` failed on both clauses because `docType != "pdf"` and `url.pathExtension == "pdf"` (`isEBook` returned `false` because it only checked original non-PDF extensions like `.epub`, `.docx`). As a result, all converted ebooks (including EPUB books with rich cover images) fell through to `return nil` without rendering thumbnails.
  - **Rule**: In `generateCoverThumbnail`, whenever `docType != "audio"`, directly check if `url.pathExtension.lowercased() == "pdf"` or if `url` is a PDF file on disk. If so, immediately load page 0 thumbnail via `PDFDocument(url: url)?.page(at: 0)`. If the file on disk is an unconverted source ebook (`MediaDocumentHelper.isEBook`), lazily call `EBookConverter.shared.ensureConvertedPDF(for: url)` before generating the PDF page thumbnail. Never assume that a document with `docType == "epub"` or `"odt"` has a non-PDF extension on disk.
- **Converter Sandbox Isolation in Unit Tests (`customDocumentsDirectory`)**:
  - **Trap**: `EBookConverter.documentsDirectory()` was hardcoded to `FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("MarginGraph/Documents")`. Running `EBookConverterTests` converted test archives into the user's permanent documents directory with varying UUIDs and timestamps, leaving duplicate copies of test books (`OpenDoc`, `TestComic`, `SpiderHero`, `QuantumComputing`) in the user's live library.
  - **Rule**: Expose a sandboxing hook `public nonisolated(unsafe) static var customDocumentsDirectory: URL? = nil` in `EBookConverter`. In unit test suites (`EBookConverterTests.setUpWithError()`), divert `customDocumentsDirectory` to an isolated subfolder in `FileManager.default.temporaryDirectory`, and purge it in `tearDownWithError()`. Never allow automated tests to write synthetic or test artifacts into `~/Library/Application Support/MarginGraph/`.
- **Same-Folder Same-Title Document Deduplication & Database Invariants (`Database+Documents.swift`, `insertDocument`)**:
  - **Trap**: Documents were previously indexed and inserted using `INSERT OR REPLACE INTO documents` keyed only by `id` or `file_path`. If different content hashes or mock test runs generated documents with different MD5s but the exact same title in the same folder, duplicate shelf cards accumulated indefinitely without restriction (e.g. six "TestComic"s or two "OpenDoc"s).
  - **Rule**:
    1. **Same-Folder Same-Title Deduplication Pass**: In `Database.syncAvailableDocuments()`, group all documents by `(folderId, title.trimmingCharacters().lowercased())`. For any group with $> 1$ document, pick the authoritative document (prioritizing records with cards, topics, physical existence on disk, and highest page count), but only retire duplicate rows with no cards or notebook references. Distinct revisions still used by another notebook must remain separate. Explicit Replace uses the catalog-retirement rule below and preserves source files.
    2. **Discovery & Insertion Prevention**: In folder scanning (`scanDirectoryForDocuments`) and `insertDocument(doc:)`, query existing documents in the folder. If a document with the same normalized title already exists, prevent inserting a duplicate record; update or merge the existing document's ID, MD5, and file path instead.
- **Immutable URI Mode for Network / SMB SQLite Databases (`SQLITE_OPEN_URI` + `file:<path>?immutable=1`)**:
  - **Trap**: Opening SQLite databases located on SMB / network shares (such as `/Volumes/omv/.../MarginNotes.sqlite` or `.marginbackupall`) using standard flags `sqlite3_open_v2(..., SQLITE_OPEN_READONLY, nil)` fails with `SQLITE_CANTOPEN` (code 14) or locking errors if WAL (`write-ahead logging`) mode was enabled when the database was written. SMB network file systems do not support the POSIX shared-memory primitives (`shm`) required for WAL index coordination, preventing the file from opening even in read-only mode.
  - **Rule**: Always enable URI handling via `SQLITE_OPEN_URI | SQLITE_OPEN_READONLY` and append `?immutable=1` (e.g. `file:\(resolvedPath)?immutable=1`) when opening external or network databases in `MarginNoteImporter`. The `immutable=1` query parameter tells SQLite that the database file is stored on read-only media and cannot change, bypassing WAL shared-memory coordination, lock files, and journal recovery completely.
- **In-Place External Database & Backup Architecture (`copyDocuments: false`, `MediaStorage.fallbackDirectories`)**:
  - **Trap**: Attempting to copy hundreds of large PDF/EPUB documents (tens of gigabytes) and tens of thousands of image attachments from external network backups into the local Application Support directory stalls the application for minutes/hours, exhausts local disk space, and violates the requirement of not duplicating external files.
  - **Rule**:
    1. Support in-place document referencing (`copyDocuments: false`) in `MarginNoteImporter`: resolve paths directly within the backup root or subfolders (`dir/fileName` and `dir/ZPATH/fileName`), saving the direct file path into SQLite without copying files.
    2. Zero local media copying (`copyMedia: false`): Configure `MediaStorage.fallbackDirectories` with external media directories (e.g. `MarginNotes.sqlite.files`). `loadImage(hash:)` and `imageURL(hash:)` check fallback directories directly on demand without duplicating files locally.
    3. Isolated Database Caching: Full CoreData SQLite import across SMB is network I/O bound (~30s for 18k cards). Cache the parsed MarginGraph SQLite database locally in `Application Support/MarginGraph/ExternalDatabases/<backupName>.sqlite`. Subsequent opens load in under 0.5s while leaving the default library (`MarginGraph.sqlite`) completely untouched. Provide seamless switching via File Menu ("Open MarginNote Database or Backup...", "Switch to Default Library", "Open Recent Library") and a persistent workspace banner.
- **Bare macOS AppKit Binary CLI Arguments Interception by `NSDocumentController` vs `WindowGroup`**:
  - **Trap**: When launching an unbundled macOS binary (`.build/.../debug/MarginGraphApp <filePath>`) from the command line, AppKit's `NSDocumentController` automatically intercepts any command-line arguments as files to open. Without an `Info.plist` declaring document types or a custom `NSDocument` subclass, `NSDocumentController.openDocument(...)` encounters an error, suppresses SwiftUI's default window creation (`count of windows == 0`), and leaves the app running invisibly in the background.
  - **Rule**: Bare binaries must be launched without path arguments (`./MarginGraphApp`). Documents and backup libraries should be opened through standard AppKit/SwiftUI mechanisms: File Menu (`⌘⇧O`), "Open Recent Library", drag-and-drop, or in-app buttons.
- **Sidebar Action Card Popovers & Modal Presentation from Dismissing Popovers (`SidebarActionCardView`, `MarginNoteSidebar`)**:
  - **Trap 1**: Calling synchronous modal dialogs (such as `NSOpenPanel.runModal()`) directly inside a SwiftUI button action that simultaneously toggles `@State isShowingPopover = false` can block popover dismissal, freeze UI responsiveness, or trap key responder focus inside an un-dismissed popover window.
  - **Trap 2**: Sizing popovers with insufficient width (e.g. 270pt) when menu items have descriptive actions like `"Open MarginNote Database or Backup…"` with icons and chevron badges leads to ugly text truncation (`"Open MarginNote Database or..."`).
  - **Trap 3 (Window Boundary Overflow with AppKit `NSPopover`)**: SwiftUI's `.popover` creates a separate AppKit `NSPopoverWindow` panel that is constrained only to the *screen's* visible frame, NOT the parent `NSWindow`'s boundary. Attaching `.popover` to edge controls (like the ellipsis button at the bottom of the sidebar) vertically centers the popover on the button, causing 50-70pt of the popover to hang outside the bottom border of the program window into the desktop.
  - **Rule**:
    1. For controls fixed at the window's edge (such as bottom sidebar actions), do not use AppKit `.popover`. Instead, render an in-window floating action card in the application's root `ZStack(alignment: .bottomLeading)` (`.zIndex(600)`), padded with `.padding(.leading, sidebarWidth + 6).padding(.bottom, 16)`. This guarantees the popup stays 100% within the program window boundary across all window sizes, screen resolutions, and positions.
    2. Provide an invisible backdrop (`Color.black.opacity(0.001).ignoresSafeArea()`) with `.onTapGesture` to dismiss on outside click, and attach `.onExitCommand` to handle Escape dismissal.
    3. Size sidebar action cards with adequate width buffer (`.frame(width: 335)`) and `.lineLimit(1)` so full item labels display cleanly without clipping.
    4. Dismiss the menu first (`isShowingSidebarMenu = false`), then dispatch modal presentation actions asynchronously on the next runloop turn via `DispatchQueue.main.async { onAction() }` so the menu is dismissed before AppKit presents modal sheets or file picker panels.
    5. Maintain consistent design language matching `DocumentActionCardView`: standard icon sizing (`16pt` frame width, `12pt` font), hover highlight (`Color.secondary.opacity(0.12)` in `RoundedRectangle(cornerRadius: 5)`), and clear hierarchical sections with subtle dividers.
- **External MarginNote Backup Import: Folder Hierarchy Preservation & Reader Topic Selection (`MarginNoteImporter`, `openDocumentInReader`)**:
  - **Trap 1 (Lost Course / Video Folder Structures)**:
    In MarginNote backups (`.marginbackupall`), multimedia lecture files and documents are stored in structured subfolders on disk (e.g. `Stanford CS230 Deep Learning/`, `tom_mitchell_machine_learning/`), recorded in `ZBOOK.ZPATH`. Previous import routines discarded `ZPATH` and flattened all documents into the root shelf (`folderId = nil`), wiping out the user's nested course organization.
  - **Trap 2 (Blank MindMap Canvas on PDF Document Open)**:
    MarginNote library databases contain two topics for each document: (1) a 0-card placeholder topic created by the MarginNote document reader, and (2) the actual study notebook topic containing tens to hundreds of note cards. When opening a document in reader mode, naive topic lookup (`topics.first(where: { $0.bookMD5List.contains(doc.md5) })`) frequently matched the 0-card reading placeholder first, opening an empty MindMap split view despite hundreds of existing cards in SQLite.
  - **Rule**:
    1. **Folder Hierarchy Extraction & Preservation**:
       During external backup and folder imports in `MarginNoteImporter`, inspect `ZBOOK.ZPATH` as well as relative filesystem subdirectory paths. Automatically synthesize `DocumentFolder` records for each unique path, assign `doc.folderId = folder.id`, and insert them via `database.insertFolder()`. Provide automatic folder repair in `Database.syncAvailableDocuments()`.
    2. **Candidate Topic Prioritization with Cards**:
       In `openDocumentInReader(document:)`, collect all candidate topics via `topic.bookMD5List`, `Database.topicIDsForCardBookMD5`, and normalized title matching. Always prioritize candidates that have cards (`cardCounts[topic.id] > 0`), selecting the notebook with the maximum card count (`candidatesWithCards.max(by: { cardCounts[$0.id] < cardCounts[$1.id] })`). Fall back to 0-card topics only when no card-bearing notebooks exist.
    3. **Indexed Reverse Card MD5 Lookup**:
       Maintain an index `CREATE INDEX IF NOT EXISTS idx_cards_book_md5 ON cards(book_md5)` in SQLite. Querying `SELECT DISTINCT topic_id FROM cards WHERE book_md5 = ? ...` provides instant $O(1)$ lookup from a document's hash to all notebooks containing its excerpts, avoiding full table scans across tens of thousands of cards.
- **Process Pipe Buffer Deadlock & Subprocess Execution (`Process`, `Pipe`, `readDataToEndOfFile`)**:
  - **Trap**: When launching a subprocess using Swift `Process()` and attaching a `Pipe()` to `standardOutput`, calling `process.waitUntilExit()` BEFORE reading `pipe.fileHandleForReading.readDataToEndOfFile()` causes an immediate permanent deadlock if the command's stdout output exceeds the macOS kernel pipe buffer size (typically 64KB). The child process blocks trying to write to the full pipe buffer, while the parent thread blocks waiting for the child to exit.
  - **Rule**:
    1. Always read pipe data (`pipe.fileHandleForReading.readDataToEndOfFile()`) BEFORE calling `process.waitUntilExit()`. This drains the OS pipe buffer in real time as data arrives and unblocks the child process.
    2. Always attach a watchdog timer (e.g. `DispatchSource.makeTimerSource` with a 5s deadline) that terminates `process` if it exceeds expected execution time to eliminate any chance of the thread hanging indefinitely.
- **PDF Thumbnail Rendering: `.cropBox` vs `.mediaBox` (`PDFPage.thumbnail(of:for:)`)**:
  - **Trap**: In PDF specifications, `MediaBox` defines the physical medium boundary (e.g., an untrimmed two-page spread or publisher imposition sheet, such as 1234.5x870 pt for a book cover with spine and back cover), while `CropBox` defines the intended display region (e.g., the 503x739 pt front cover). Using `page.thumbnail(of: size, for: .mediaBox)` for document covers renders the entire imposition sheet, resulting in a tiny, squished cover offset to the right with a large blank gap on the left (as observed on *Chapman & Hall_CRC Machine Learning*).
  - **Rule**: Always render document thumbnails using `for: .cropBox` (`let box: PDFDisplayBox = (page.bounds(for: .cropBox).width > 0 && page.bounds(for: .cropBox).height > 0) ? .cropBox : .mediaBox`). Never use `.mediaBox` unconditionally for shelf cover previews.
- **Native EPUB Cover Art Extraction vs WebKit HTML-to-PDF Conversion**:
  - **Trap**: Converting EPUB cover documents (`01_Cover.xhtml`) via WebKit to PDF applies browser styling (such as viewport scales, default margins, and unconstrained wrapper `<div>`s with `height: 95vh`), causing the cover image to render as a miniature postage-stamp graphic centered in an empty white PDF canvas. Generating a PDF thumbnail from that page shrinks the image twice, producing tiny unreadable shelf covers.
  - **Rule**:
    1. Implement native EPUB cover extraction (`MediaDocumentHelper.extractEPUBCoverImage(url:)`): inspect `container.xml` -> OPF manifest for EPUB 3 `properties="cover-image"`, EPUB 2 `<meta name="cover" content="...">` (resolving both manifest IDs and direct relative paths), `<item id="cover">`, guide `<reference type="cover">`, and cover image fallbacks.
    2. Extract the original high-resolution JPEG/PNG artwork directly from the EPUB ZIP archive via `/usr/bin/unzip -p` in under 250ms without invoking WebKit or PDFKit conversions.
    3. Persist extracted covers into `Application Support/MarginGraph/Thumbnails/epub_<md5>.jpg` and cache in memory via `coverThumbnailCache` (`NSCache`), giving sub-millisecond shelf rendering on subsequent visits.
- **External Library Discovery & Default Storage Isolation (`syncAvailableDocuments(libraryRoot:)`)**:
  - **Trap**: In `Database.syncAvailableDocuments()`, scanning the default `~/Library/Application Support/MarginGraph/Documents` directory unconditionally causes sample and default library books (such as *Scarlet*, *OpenDoc*, *MobiBook*) to be inserted into external backup databases when opened, polluting the external library shelf.
  - **Rule**:
    1. When an external library is opened (`libraryRoot != nil`), strictly limit document discovery search paths to `[libraryRoot] + additionalSearchPaths`. Never add the default `MarginGraph/Documents` folder.
    2. In step 1 of `syncAvailableDocuments()`, when `libraryRoot != nil`, actively purge any records in `documents` whose `filePath` points inside the default Application Support documents directory.
- **EPUB Typography, Font Normalization & Reflowable Document Dimensions (`EBookConverter`, PyMuPDF, WebKit)**:
  - **Trap (Bloated / Unstable EPUB Font Sizes & Viewport Scaling)**:
    1. By default, PyMuPDF (`doc.convert_to_pdf()`) defaults to a tiny `400 x 600 pt` viewport.
    2. When publisher stylesheets include explicit pixel/point font rules (e.g. `Style01.css` specifying `p { font-size: 18px; }`), PyMuPDF renders body text at `18.0 pt` on the 400pt-wide canvas.
    3. In `MarginGraphApp`, the split-pane PDF reader scales the 400pt page to fit the ~750-800pt viewer pane (`autoScales = true`), magnifying the 18pt font by ~1.9x into an enormous ~34pt visual appearance on screen with only 3–5 words per line and ballooning page counts (e.g. Autotools ballooned to 1,815 pages).
    4. Conversely, EPUBs without explicit CSS font overrides fell back to 10–11pt, producing severe font size instability across different EPUB titles.
    5. Calling `doc.layout(..., fontsize=11)` alone does NOT override publisher CSS font rules because element-level selectors (`p { font-size: 18px }`) take precedence over the layout base font.
  - **Rule**:
    1. **Universal CSS Normalization**:
       Inject standardizing CSS targeting `body, p, div, li, a, td, th` with `font-size: 11pt !important; line-height: 1.45 !important;`. Provide proportional heading scales (`h1: 20pt`, `h2: 16pt`, `h3: 13.5pt`, `h4: 12pt`, `h5/h6: 11pt`), monospace code styling (`code, pre: 9.5pt !important; white-space: pre-wrap !important`), proportional annotations (`small: 9pt`, `sup/sub: 8pt`), and responsive images (`img: max-width: 100% !important; height: auto !important`).
    2. **PyMuPDF Engine**:
       For all reflowable documents (`getattr(doc, 'is_refl', getattr(doc, 'is_reflowable', False))`), apply custom CSS via `doc.apply_css(css, append=True)` and set standard A4 paper dimensions via `doc.layout(width=595, height=842, fontsize=11)`. Standard A4 (595pt width) matches desktop split-pane aspect ratios (zoom scale ~1.1x–1.3x) and guarantees consistent ~12–16 words per line.
    3. **Native WebKit Engine**:
       Inject the identical normalizing CSS into `WKWebViewConfiguration` via `WKUserScript(source: ..., injectionTime: .atDocumentEnd)` and reinforce it during `webView(_:didFinish:)`. Render PDF pages with standard A4 bounds (`width: 595, height: max(842, scrollHeight)`).
    4. **Subprocess Pipe Deadlock & MuPDF Error Suppression**:
       Suppress MuPDF C-level warnings via `pymupdf.TOOLS.mupdf_display_errors(False)` and `pymupdf.TOOLS.mupdf_display_warnings(False)`. When invoking Python via `Process()`, always drain `errorPipe` asynchronously in a background queue before calling `process.waitUntilExit()`.
    5. **Layout Versioning & Cache Invalidation (`layout_ver`)**:
       Persist a layout version sidecar (`<md5>.layout_ver = "v2_std_font"`). In `ensureConvertedPDF`, check if reflowable documents have a matching `layout_ver`. If the sidecar is missing or outdated, automatically remove the stale PDF and re-convert, ensuring users immediately enjoy standardized fonts without needing to manually clear caches.



- **Custom Typography Controls & Variant Caching for Reflowable eBooks (`TypographyOptions`, `EBookConverter`)**:
  - **Baseline Font Size Selection**:
    Analysis of standard professional digital book PDFs (e.g. *How to Take Smart Notes*, *Save the Cat!*) demonstrates that body text renders at ~14.4–15.0 pt on US Letter / A4 width pages. Setting baseline reflowable eBook body font size to 15.0 pt provides optimal desktop split-view readability (~10–12 words / 55–65 characters per line). Headings scale proportionally (`h1: 26pt`, `h2: 21pt`, `h3: 18pt`, `h4: 16pt`, `h5/h6: 15pt`), code blocks at `13pt`, and line-height defaults to `1.50`.
  - **Multi-Setting Variant Caching**:
    Store re-rendered reflowable PDFs using deterministic cache keys (`<md5>_<cacheKey>.pdf`, e.g. `<md5>_v3_fs18_ls1.50_system.pdf`) alongside the active `<md5>.pdf`. When the user switches between previously selected font sizes or styles, copy from the cached variant instantly (<10ms) without re-running PyMuPDF or WebKit re-conversion.
  - **Source File Path Sidecars (`.source_path`)**:
    MarginNote library databases store the converted PDF path (`.../<md5>.pdf`) in `document.filePath`. To enable dynamic re-conversion with new typography preferences, write a `.source_path` sidecar alongside `<md5>.pdf` containing the absolute path of the original `.epub`/`.mobi` file. `MediaDocumentHelper.resolveSourceURL` and `PDFDocumentManager` resolve the original reflowable source file from this sidecar.
  - **Proportional Reading Position Preservation**:
    When font size or line spacing changes, the total page count shifts. Preserve the user's reading position across reflow re-renders by calculating proportional progress (`Double(currentPage) / Double(oldTotalPages)`), re-converting, and restoring `newPageIndex = Int(round(progress * Double(newTotalPages)))`.

- **In-Window Popovers vs Native AppKit NSPopover Boundary Overflow (`InWindowPopoverContainer`)**:
  - **Trap (Popover Exceeding Program Boundary)**:
    Using native SwiftUI `.popover(isPresented:arrowEdge:)` creates an AppKit `NSPopover` in a separate floating window. When attached to toolbar buttons positioned near the edge of a pane or window (such as the `"textformat.size"` `AA` button on the far right of the PDF toolbar), AppKit attempts to center the popover horizontally on the anchor button. When the button is closer to the window border than half the popover width, the popover card bleeds outside the boundary of the application window, obscuring external apps or clipping outside display bounds.
  - **Rule**:
    1. **Never use native `.popover(isPresented:)` for edge-adjacent toolbar buttons**:
       Always host toolbar popovers (TOC, Bookmarks, Reading Appearance / Typography) inside `InWindowPopoverContainer`.
    2. **Anchor Geometry & Clamping**:
       Record the button's bounds via `GeometryReader` into `PDFToolbarButtonFrameKey.self` preference key. In the container overlay, `InWindowPopoverContainer` computes:
       `let effectiveWidth = min(popoverWidth, max(180, containerWidth - margin * 2))`
       `let left = max(margin, min(idealLeft, containerWidth - effectiveWidth - margin))`
       This mathematically guarantees that the popover card is strictly confined within `[margin, containerWidth - effectiveWidth - margin]`.
    3. **Dynamic Pointer Arrow Alignment**:
       `PopoverBubbleShape(arrowX: anchorFrame.midX - left)` dynamically shifts the arrow along the top edge of the card to point directly at the button's center, even when the card itself is clamped at the window edge.
    4. **Responsive Content Width**:
       Specify `.frame(maxWidth: popoverWidth)` rather than a fixed `.frame(width: popoverWidth)` on popover content views (like `TypographySettingsPopoverView`) so the view gracefully adapts if the container or split pane is resized narrower than the default width.

- **Mandatory Boundary Containment for All Buttons, Menus & Dropdowns (`NSMenu` / `Menu` Trailing Edge Overflow)**:
  - **Trap (Native AppKit `Menu` / `NSMenu` Bleeding Past Window Edge)**:
    SwiftUI's `Menu` on macOS wraps AppKit's `NSMenu` / `NSPopUpButton`. By default, AppKit anchors the popup menu to the button's leading edge (`minX`) and expands downwards and to the right. SwiftUI provides no alignment API (such as trailing edge alignment) for `Menu`. When a `Menu` is attached to a button situated near the trailing edge of a toolbar, header, or pane (such as the `"..."` Document Options button), the menu card extends 100–160pt beyond the right edge of the program window, visually breaking containment, clipping on display edges, and obscuring other desktop applications.
  - **Rule**:
    1. **Mandatory Check Whenever Modifying or Adding Any Button, Menu, Popover, or Dropdown**:
       Before declaring any task complete that touches a button, menu, dropdown, or popover, agents MUST verify and guarantee that all openable UI elements stay strictly within the program window boundaries.
    2. **Never Use Native SwiftUI `Menu` Near Trailing Pane or Window Edges**:
       Replace edge-aligned `Menu` controls with standard SwiftUI `Button` triggers that present custom popover cards hosted inside `InWindowPopoverContainer` (such as `DocumentOptionsMenuView`).
    3. **Window Clamping & Arrow Alignment**:
       By capturing the button's frame in `.named("PDFContainerSpace")` and hosting within `InWindowPopoverContainer`, the menu is strictly clamped within `[margin, containerWidth - effectiveWidth - margin]`, while the arrow tip automatically shifts to point at the button's center.
    4. **Interactive Live Testing Verification**:
       You MUST launch the app (`.build/arm64-apple-macosx/debug/MarginGraphApp`), click every newly added or modified button/menu, capture screenshots, and verify visually that no dropdown, popover, or menu extends past the program window boundary.

- **High-Performance SQLite Initialization & FTS Search Indexing (`PRAGMA user_version`)**:
  - **Trap**:
    Calling `INSERT INTO cards_fts(cards_fts) VALUES('rebuild');` on every database connection open forces SQLite to scan every note card and re-tokenize all text content into the full-text search index. In libraries with 15,000+ cards, this rebuild alone took ~0.85s on every startup or library switch. In addition, re-running multiple `CREATE TABLE IF NOT EXISTS`, `CREATE INDEX IF NOT EXISTS`, and column PRAGMAs on every connection creates unnecessary I/O overhead.
  - **Rule**:
    1. **Guard Schema Creation with `PRAGMA user_version`**:
       On `Database.init`, query `PRAGMA user_version;`. If `version >= currentSchemaVersion` (e.g. `3`), return immediately without executing DDL statements, PRAGMA checks, or FTS rebuilds.
    2. **Initial Setup Only**:
       Only rebuild FTS5 or run table creation when `version == 0` (fresh database). Triggers (`cards_ai`, `cards_ad`, `cards_au`) keep the FTS index automatically synchronized for all subsequent inserts, updates, and deletes.
    3. **Benchmark Impact**:
       Dropping redundant schema validation and FTS rebuilds reduces `Database.init` from **0.849s down to 0.001s (over 800x speedup)**.

- **Network Share (SMB/NFS) Directory Traversal & Document Discovery Optimization**:
  - **Trap**:
    Using `FileManager.default.enumerator` without directory pruning across network drives (e.g. `/Volumes/omv/...`) causes the enumerator to recurse into thousands of internal resource files (e.g. `MarginNotes.sqlite.files` containing 3,800+ sidecar images and temporary files). Every file stat over SMB incurs high roundtrip network latency. Furthermore, querying SQLite inside the loop for every file path turns directory scanning into an $O(N)$ network and database bottleneck taking 3–6 seconds.
  - **Rule**:
    1. **Prune Non-Document Subtrees (`skipDescendants()`)**:
       Inspect directories during enumeration with `resourceValues(forKeys: [.isDirectoryKey])`. If the folder is an internal cache/files directory (e.g. `MarginNotes.sqlite.files`, `files`, `.git`, `.marginnotes`, `.marginpkg`), call `enumerator.skipDescendants()` immediately.
    2. **In-Memory Set Membership Filtering**:
       Pre-fetch all existing document `filePath` and `md5` values into `Set<String>` collections (`existingPaths`, `existingMD5s`) before starting directory enumeration. Checking `existingPaths.contains(fileURL.path)` in memory allows skipping already registered files in sub-microsecond time with zero filesystem or database queries.
    3. **Benchmark Impact**:
       Directory enumeration and document discovery drops from **2.768s to 0.307s (9x speedup)**.

- **Grouped Metadata Queries & Batched Transactions in Maintenance Passes (`repairTopicBookMD5Lists`)**:
  - **Trap**:
    In maintenance functions like `repairTopicBookMD5Lists`, running `cardsForTopic(id: topic.id)` inside a loop across 400+ topics executes 400+ individual SQL queries, instantiates 15,000+ full `NoteCard` Swift structs, re-normalizes strings for every topic-document pair ($438 \times 36$ comparisons), and executes un-batched `updateTopic` queries that each trigger an SQLite transaction and disk sync.
  - **Rule**:
    1. **Single Grouped Query**:
       Query card associations in a single statement: `SELECT topic_id, book_md5 FROM cards WHERE book_md5 IS NOT NULL AND book_md5 != '' GROUP BY topic_id, book_md5`. This constructs the entire topic-to-book mapping in one SQL query (~3ms).
    2. **Precomputed Normalized Strings**:
       Pre-normalize document titles and filenames into a lightweight struct (`PreparedDoc(md5, lowerTitle, lowerFileName)`) before the loop. Perform exact dictionary lookups first (`docByMD5[cmd5]`), falling back to prefix matching only when needed.
    3. **Batch Mutations with Transactions**:
       Collect all modified topics in a list (`topicsToUpdate`) and commit them inside a single `db.transaction { ... }`.
    4. **Benchmark Impact**:
       Topic book repair time drops from **1.016s to 0.161s (6x speedup)**.

- **Instant Cached-Open & Decoupled Background Document Sync**:
  - **Trap**:
    Synchronously running document discovery and database repair passes on the `@MainActor` thread during `openMarginNoteBackup` blocks the user interface with a progress modal or spinning beachball, even when the user has already opened the backup previously and all data is cached.
  - **Rule**:
    1. **Instant UI Activation for Cached Databases**:
       If `cacheDbURL` already exists, immediately assign `self.database = newDb`, register media fallback directories, reset workspace, reload library, and dismiss `isOpeningDatabase = false`. The library displays in under **25ms**.
    2. **Asynchronous Background Sync**:
       Dispatch `syncAvailableDocuments(libraryRoot: backupDir)` to `Task.detached(priority: .utility)`. Upon completion, hop back to `@MainActor` to call `reloadLibrary()` only if `self.activeDatabaseURL == backupDir`. The user experiences zero lag or modal interruption.

- **MarginNote Synthetic Document Root Card Detection & MindLinks Reachability Pruning**:
  - **Trap**:
    In MarginNote external libraries (`MarginNotes.sqlite`, `.marginnotes`, `.marginbackupall`, and `.marginpkg`), MarginNote creates a synthetic "document note card" representing the document itself as the parent/ancestor of all other note cards in the topic. This card has empty highlight text, empty notes text, empty highlight rects, no start page, and no highlight pic hash. In MarginNote's underlying database, parent-child mindmap hierarchy is frequently stored in `ZMINDLINKS` (pipe-delimited child IDs) rather than `ZGROUPNOTEID`. Displaying this synthetic root card clutters the mindmap by wrapping all actual user note cards under a redundant document container card.
  - **Rule**:
    1. **Strict Synthetic Card Detection Invariants**:
       Identify the synthetic document root card using `NoteCard.filterMarginNoteDocumentRootCard(from:)`:
       - Must be a candidate root: `card.groupNoteId == nil`.
       - Must be strictly synthetic: `card.highlightText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty`, `card.notesText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty`, `card.highlightRects.isEmpty`, `card.startPage == nil`, `card.highlightPicHash == nil`.
       - Structural reachability validation:
         - *Hierarchy via `groupNoteId`*: Card is the sole root and its descendants count equals `cards.count - 1`.
         - *Hierarchy via `mindLinks`*: BFS reachability traversal through `mindLinks` reaches $\ge 80\%$ of all other cards, and no other card links to it (`isTargetOfOther == false`).
    2. **Child Card Promotion & Reference Pruning**:
       - When the synthetic document root card is excluded, promote all its direct children (`groupNoteId == rootCard.id`) to roots (`groupNoteId = nil`).
       - Prune links (`mindLinks`) and review items referencing the removed card.
    3. **Strict Scope Limitation**:
       - ONLY apply this filtering to MarginNote libraries, `.marginbackupall`, and `.marginpkg` import (guarded by `isExternalDatabase == true` or inside the MarginNote importer).
       - NEVER filter user-created root note cards (cards with text, excerpts, or page coordinates).
       - NEVER apply this filtering to native MarginGraph notebooks.
- **MarginNote `ZMEDIA` Binary Plist Image Storage & Dynamic Fallback Media Resolution**:
  - **Trap**:
    In MarginNote libraries and `.marginbackupall` backups, rectangular / area / lasso excerpts (frequent in math, code, engineering, and science notebooks like Chapman & Hall ML) store `ZHIGHLIGHT_TEXT = NULL`, `ZNOTETITLE = NULL`, and `ZNOTES_TEXT = ""` while populating `ZHIGHLIGHT_PIC` (media hash) and `ZHIGHLIGHTS` (page coordinates).
    1. **Loose Files vs Database Storage**: Out of thousands of excerpt images, the vast majority (e.g. 1,800+ of 2,500+) are stored exclusively in the CoreData SQLite database table `ZMEDIA.ZDATA`, rather than as loose files in `MarginNotes.sqlite.files`.
    2. **`bplist00` NSKeyedArchiver Serialization**: MarginNote wraps raw image bytes in an Apple `NSKeyedArchiver` binary property list (`bplist00`). Passing raw `ZMEDIA.ZDATA` to `NSImage(data:)` fails completely because `NSImage` cannot decode binary plists.
    3. **Blank Cards in MindMap**: If `card.title`, `card.highlightText`, and `card.notesText` are empty and `thumbnail` fails to load, `CardNodeView` rendered as an empty cream box with "Untitled Note", concealing the excerpt entirely.
  - **Rule**:
    1. **Universal Image Extraction (`extractImageData(from:)`)**:
       Inspect blob magic bytes (`PNG`, `JPEG`, `GIF`, `TIFF`, `HEIC/AVIF`). If the payload starts with `bplist00`, parse the property list via `PropertyListSerialization` and extract the image `Data` object from the `$objects` array by validating inner magic bytes.
    2. **Thread-Safe SQLite Database Fallback in `MediaStorage`**:
       Configure `MediaStorage.fallbackDatabaseURL`. In `loadImage(hash:)`, if the file is not found in the local disk cache or fallback directories, query `SELECT ZDATA FROM ZMEDIA WHERE ZMD5 = ?` from the external SQLite database (using a thread-safe connection queue with `?immutable=1`). Unpack using `extractImageData` and populate memory cache (`NSCache<NSString, NSData>`).
    3. **MindMap Card Node Visual Rendering**:
       In `CardNodeView`, prioritize visual excerpt display: if `thumbnail != nil` (`hasImage`), display the visual crop in the card body with user notes (`notesText`) below it. Only show extracted text when `hasExcerpt && !hasImage`. Guard the "Untitled Note" fallback header behind `!hasExcerpt && !hasNotes && !hasImage`.
    4. **PDF Text Backfill for Search & SRS**:
       When area excerpt cards have empty `highlightText` but valid `highlightRects` and associated PDF documents, extract text from `PDFDocument` selections at `card.highlightRects` (both at import time and lazily upon topic load) and batch-update cards in SQLite. This ensures FTS5 full-text search, SRS review decks, and plain-text export function seamlessly for rectangular highlights.

- **`.marginbackupall` UTI Type & `NSOpenPanel` Package Selection Trap**:
  - **Trap**:
    MarginNote backup bundles (`.marginbackupall`) are package directories declared under UTI `com.qreader.marginnote.marginbackupall`. In Apple Uniform Type Identifiers, this conforms to `com.apple.package` (`UTType.package`), NOT `.folder`.
    When configuring `NSOpenPanel.allowedContentTypes = [.folder]`, macOS greys out `.marginbackupall` bundles in the file picker, preventing users from opening external backups.
  - **Rule**:
    In file pickers opening MarginNote databases or backups, always include:
    `[UTType.package, UTType.folder, UTType.database, UTType.sqlite3, UTType("com.qreader.marginnote.marginbackupall"), UTType("com.qreader.marginnote.marginbackup"), UTType("com.qreader.marginnote.marginpkg")]` (compact-mapped), and set `panel.allowsOtherFileTypes = true`.

- **Sidecar Working Directory Pattern for External Backup Preservations**:
  - **Trap**:
    Overwriting or modifying the original `.marginbackupall` archive or file bundle when users create notes, edit titles, or modify notebooks is inefficient, slow, and risks corrupting original user backups.
  - **Rule**:
    1. **Strictly Immutable Source Backup**:
       Treat the original `.marginbackupall` file or directory as strictly read-only.
    2. **Sidecar Working Folder**:
       Resolve a sidecar directory next to the `.marginbackupall` file named after the backup (or user-defined library alias):
       `backupURL.deletingLastPathComponent().appendingPathComponent(alias.isEmpty ? backupURL.deletingPathExtension().lastPathComponent : alias)`.
    3. **Isolated Working Database**:
       Place `MarginGraph.sqlite` inside the sidecar folder. On first launch, initialize it from the backup or legacy cache. Connect `self.database` directly to `workingDbURL`. If the user updates the library alias in Library Management, automatically rename the sidecar folder on disk to match.

- **MarginNote Package Exporter (`MarginPackageExporter`) CoreData Architecture**:
  - **Trap**:
    Attempting to construct a MarginNote `.marginpkg` from scratch by writing ad-hoc tables fails because MarginNote requires strict CoreData metadata (`Z_METADATA`, `Z_PRIMARYKEY`, `Z_MODELCACHE`, NSStoreUUID, entities `ZBOOKCONFIG`, `ZTOPIC`, `ZBOOKNOTE`, `ZMEDIA`). Furthermore, zip archives without Mac OS X extended attributes (`__MACOSX`) or zipped with standard tools can fail MarginNote checksum checks.
  - **Rule**:
    1. **Embedded Template SQLite Database**:
       Embed a clean, minimal, gzipped `.marginnotes` CoreData SQLite template in code. At export time, decompress to a temporary folder, and populate using standard SQLite queries.
    2. **Coordinate & Page Number Mapping**:
       MarginNote page numbers in `ZSTARTPAGE` and `ZENDPAGE` are 1-based (add 1 to 0-based page indexes). Encode `highlightRects` into binary property lists (`ZHIGHLIGHTS`) matching MarginNote's `{{x, y}, {w, h}}` string array schema.
    3. **Ditto Archiving**:
       Archive `.marginpkg` using `ditto -c -k --sequesterRsrc <stagingDir> <targetPkgURL.path>` to produce valid, MarginNote-compatible PKZip archives with resource fork safety.

- **AppModel Single Source of Truth for Menu Bar Commands and Modal Sheets**:
  - **Trap**:
    In SwiftUI on macOS, declaring modal presentation state as `@State` inside the `App` struct (`@State private var isShowingManageLibraries = false`) creates a disconnected state slice. Menu bar commands in `CommandGroup` modifying that `@State` or views calling closures can fail to trigger SwiftUI scene updates or dismiss sheets unpredictably.
  - **Rule**:
    Always place sheet and modal presentation states on the `@MainActor` `AppModel` (`@Published var isShowingManageLibraries = false`). Bind sheets using `.sheet(isPresented: $model.isShowingManageLibraries)` and invoke from menus or views with `model.isShowingManageLibraries = true`.

- **SQLite WAL Mode Incompatibility on SMB / NFS Network Volumes**:
  - **Trap**:
    SQLite's Write-Ahead Logging (WAL) mode requires POSIX shared memory / `mmap` for the shared memory index file (`<db>-shm`). Network filesystems such as SMB, NFS, and AFP do not support shared memory mapping or POSIX file locks suitable for WAL indexing. Opening or querying a WAL-mode SQLite database located on an SMB network share fails immediately with `SQLITE_CANTOPEN` (14) (`"unable to open database file"`), preventing external backup databases (e.g. sidecar databases on NAS storage) from loading. Furthermore, if a database file was created locally in WAL mode and then copied to an SMB share, its page 1 header bytes 18 & 19 retain version `2` (WAL mode), which causes SQLite to fail on open before executing any user `PRAGMA`.
  - **Rule**:
    1. **Network Volume Detection**:
       Check whether database URLs reside on remote filesystems using `URLResourceValues.volumeIsLocalKey` (traversing up parent directories if the target path does not yet exist).
    2. **Rollback Journal Mode for Network Volumes**:
       When opening databases on remote/network filesystems, strictly enforce `PRAGMA journal_mode = DELETE;` (or `TRUNCATE`). Only use `PRAGMA journal_mode = WAL;` on local volumes (`volumeIsLocal == true`).
    3. **Page 1 Header Sanitization & Local Temp Checkpointing**:
       Before opening an existing database on a network volume, inspect the first 100 bytes of the file. If bytes 18 or 19 equal `2` (indicating WAL format), copy the database and its `-wal` / `-shm` sidecars to a local temporary directory on APFS, open it locally, execute `PRAGMA wal_checkpoint(TRUNCATE);` followed by `PRAGMA journal_mode = DELETE;`, close it, and replace the network file with the sanitized rollback-journal database.
- **Package Container Boundary Invariant vs Relative Path Prefix Delimiter Trap in `repairDocumentFolders`**:
  - **Trap**:
    When repairing document folder assignments by matching physical subdirectories against the library path, using `parentDir.hasPrefix(libPath)` without ensuring a path delimiter (`/`) causes false matches when companion sidecar folders share names with `.marginbackupall` bundles (e.g. `parentDir` = `/path/MarginNoteBackup.marginbackupall` matched `libPath` = `/path/MarginNoteBackup`). Stripping the prefix produced `.marginbackupall`, which created a bogus folder named `.marginbackupall` and trapped root documents inside it. Furthermore, `.marginbackupall` and `.marginpkg` files are bundle archives/packages, never user folders.
  - **Rule**:
    1. **Strict Path Delimiter Boundary**: Always enforce path component boundaries (e.g. ensuring `parentDir == libPath || parentDir.hasPrefix(libPath.hasSuffix("/") ? libPath : libPath + "/")`) before computing relative paths.
    2. **Package Container Invariant**: Any path component matching `*.marginbackupall` or `*.marginpkg` is a package archive container, NEVER a user folder. Any document directory directly inside that component represents the library root (`folder_id = nil`).
    3. **Automated Folder Repair**: In `repairDocumentFolders()`, detect and eliminate bogus folders named `.marginbackupall` or ending in `.marginbackupall` / `.marginpkg`, reset their documents to `folder_id = nil`, and merge child folders into existing root folders.

- **LibraryManager Companion Consolidation & Dual-Mode Default Switching**:
  - **Trap**:
    Users can open or register either the `.marginbackupall` package or the extracted sidecar working directory in `LibraryManager`. Both point to the same library and sidecar SQLite database. Registering both created duplicate entries, conflicted user-set `isDefault` flags, and caused "Switch to Default Library" to revert to built-in storage instead of the user's chosen default library.
  - **Rule**:
    1. **Companion Entry Consolidation**: In `LibraryManager`, consolidate companion entries (`.marginbackupall` bundles and matching sidecar directories) into a single unified record, preserving user aliases, working folder paths, and `isDefault` flags.
    2. **Dual-Mode Default Library Switching**: `AppModel.init()` and `switchToDefaultDatabase()` must check `LibraryManager.shared.defaultLibrary`. If the default library is external, open `defaultLib.path`; if built-in, open Application Support. The top banner must dynamically show a blue `DEFAULT` badge and `Switch to Built-in Library` when the active external library is the default.
    3. **Explicit Action Labels & Universal Shelf Access**: Always provide a prominent `[Manage Libraries…]` button in the document shelf header bar across all libraries. In modal management cards, avoid ambiguous icon-only buttons; use explicit text buttons (`[Rename Library]`) with inline editing fields.

- **PDF Highlight Extraction & Consecutive Note Clustering Importer (`PDFHighlightImporter`)**:
  - **Trap**:
    When PDFs highlighted by external viewers (e.g. Preview, Acrobat, GoodNotes, Skim, MarginNote) are imported into MarginGraph:
    1. Highlights are often split into multiple sub-annotations or line-by-line fragments even when they belong to the same sentence or paragraph.
    2. Blindly treating every PDF highlight annotation as an isolated card floods study notebooks with hundreds or thousands of fragmented single-line notes (e.g. 892 raw annotations in *Homo Deus* collapsing down to 251 coherent note cards).
    3. Treating general punctuation (like periods, exclamation marks, semicolons) as ignorable between highlights causes separate sentences and distinct thoughts to be incorrectly merged into one card.
    4. Using LaunchServices `open -a <executable>` to test raw command-line debug binaries fails with OS status -10811 because the executable in `.build/` is a raw binary, not an `.app` bundle.
  - **Rule**:
    1. **Two-Stage Sequential User Decision Dialogs (`NSAlert`)**:
       - Alert 1: Check if PDF contains highlights (`PDFHighlightImporter.hasHighlights(in:)`). If found, ask user whether to convert highlights into notebook cards (`[Turn into Cards]`, `[Skip]`).
       - Alert 2: If yes, ask user whether to merge consecutive notes (`[Merge Consecutive Notes]`, `[Keep Separate Cards]`, `[Cancel]`).
       - Run both synchronously on `@MainActor` in sequence before performing database operations.
    2. **Strict Consecutive Note Adjacency Criteria**:
       - Two highlights $H_1, H_2$ are consecutive if and only if:
         a) They are adjacent in document reading order (same page and $H_2$ follows $H_1$ vertically/horizontally, OR consecutive pages where $H_1$ is at the bottom of page $N$ and $H_2$ is at the top of page $N+1$).
         b) They have the exact same color / palette index (`colorIndex(for:)`).
         c) The text between them in the document text stream contains strictly zero non-whitespace characters except word-break hyphens (`CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-‐‑‒–—"))`). Never ignore standard punctuation or sentence boundaries.
    3. **Non-Destructive PDF Handling**:
       - Keep the original PDF file completely intact and untouched. Highlights are imported purely as `NoteCard` records attached to a dedicated study topic with accurate PDF page references and bounding boxes.
     4. **On-Demand Access & Boundary Clamping**:
       - Expose "Import PDF Highlights…" in the shelf document card menu (`DocumentActionCardView`), shelf right-click context menu, and the reader top toolbar `...` popover menu (`DocumentOptionsMenuView`), strictly clamped within window bounds via `InWindowPopoverContainer`.
    5. **CLI Launch Argument Support for Headless/Agent Testing**:
       - Support `--import-document <path>` in CLI arguments so agents can launch and test document import workflows directly from `.build/arm64-apple-macosx/debug/MarginGraphApp` without relying on `open -a` or system file dialog interaction.

- **PDF Highlight Perceptual Color Matching & Collision-Free Hungarian Bipartite Assignment**:
  - **Trap**:
    1. **Euclidean RGB Distance vs Perceptual Hue Trap**:
       Comparing PDF highlighter colors to app palette colors in standard Euclidean RGB space (`sqrt(dr^2 + dg^2 + db^2)`) produces severe misclassifications. For example, standard bright yellow highlighter pens (`#fff7c7`, RGB `1.0, 0.969, 0.779`) compared to MarginGraph pastel yellow (`#f3eca0`, index 0, RGB `0.953, 0.925, 0.627`) have a large blue difference ($\Delta b = 0.152$). In Euclidean RGB space, this yellow highlight is falsely closer to Peach (`#fed7aa`, index 12, $\Delta b = 0.034$), causing yellow highlights in PDFs to turn into peach cards. Human vision distinguishes highlight markers almost entirely by hue angle ($\sim 52^\circ$ for yellow vs $55^\circ$ for MarginGraph yellow vs $21^\circ$ for peach).
    2. **Nearest-Neighbor Color Collisions**:
       Mapping each PDF highlight independently to its nearest palette color causes distinct colors used in the same document (e.g. Lime Green vs Pure Green, or Sky Blue vs Teal) to collapse into the exact same MarginGraph palette slot (e.g. Green index 1). This destroys the reader's visual hierarchy and causes `areConsecutive` to erroneously merge distinct-color highlights into single cards.
  - **Rule**:
    1. **HSV Circular Perceptual Distance**:
       Convert colors to HSV and compute circular hue difference: `min(|h1 - h2|, 360 - |h1 - h2|)`. Weight hue heavily over saturation and value: `distance = (hueDiff^2 * 5.0) + (satDiff^2 * 0.5) + (valDiff^2 * 0.5)`. Apply gray penalties when mapping chromatic highlights to low-saturation grays.
    2. **Document-Level Hungarian Bipartite Matching (Collision-Free)**:
       Before importing highlights from a document, cluster all unique highlight pen colors in the PDF (Euclidean distance threshold $\le 0.035$). If $N$ clusters exist ($N \le 16$), assign each cluster to a unique MarginGraph palette index using the Hungarian algorithm (minimum-weight bipartite matching on the $N \times 16$ cost matrix). This ensures globally minimal perceptual distortion while strictly guaranteeing zero color collisions across the document.
    3. **Double-Guarded Consecutive Note Merging**:
       In `areConsecutive(h1:h2:in:)`, require both `h1.colorIndex == h2.colorIndex` AND raw PDF color consistency (`isSamePDFColor(h1.color, h2.color, threshold: 0.04)`), preventing disparate pens from merging even if mapped close together.

- **Intra-Line PDFKit Spurious Newline Cleanup & Punctuation Attachment (`cleanPhysicalLineText`)**:
  - **Trap**:
    Apple PDFKit's `page.selection(for: lineBox)?.string` injects spurious newline characters (`\n`) between adjacent text runs, font styling shifts, or `Tj` operator chunks even within a single physical line (e.g. `across its mind.\n‘There was something...`, `mushroom clouds. Oh well, it was just a bad dream.\n’ Going to the bathroom,`, `‘God’s will be done’\n. Rather,`). Blindly extracting or joining selections orphans punctuation and quote marks onto separate lines and corrupts card excerpts.
  - **Rule**:
    Process physical line text with `cleanPhysicalLineText(from:)`:
    1. Split line text by newlines and trim whitespace.
    2. Join chunks using character attachment rules: attach closing quotes (`’`, `'`, `”`, `"`) and punctuation (`,`, `.`, `;`, `:`, `!`, `?`, `)`) to the preceding word without spaces.
    3. Separate regular words and opening quotes with a single space.
    Extracted physical lines are guaranteed to be clean, single-line strings without internal spurious breaks.

- **Strict Sentence & Paragraph Boundary Detection in Consecutive Highlight Merging**:
  - **Trap**:
    Using naive `.hasSuffix(".")` to detect completed sentences fails when an excerpt ends with sentence-ending punctuation followed by closing quotes, parentheses, brackets, or footnote citations (e.g. `die from them.)` or `bad dream.’`). The failed suffix check allows distinct paragraphs (such as an indented opening sentence of the next paragraph) to merge across paragraph or page boundaries ($N \to N+1$).
  - **Rule**:
    1. **Punctuation Trimming Before Suffix Checking**:
       Strip trailing closing characters (`"”\"'’)]}）】」』”’"`) before checking whether an excerpt ends with sentence-ending punctuation (`endsWithPunct`: `.`, `!`, `?`, `;`, `:`).
    2. **Paragraph Boundary Guards**:
       If an excerpt ends with sentence-ending punctuation, check whether it terminates a paragraph using layout geometry:
       - `isShortLine`: line width is shorter than standard column width (ragged right margin).
       - `isNextIndented`: the next highlight line starts significantly to the right (paragraph indentation).
       If either condition holds, treat the boundary as a distinct paragraph and do NOT merge consecutive highlights.
    3. **Cross-Page Paragraph Preservation**:
       In cross-page merging ($N \to N+1$), completed paragraphs at the bottom of page $N$ (`endsWithPunct && (isShortLine || isNextIndented)`) must never merge into new paragraphs at the top of page $N+1$.

- **Startup $O(N^2)$ Deduplication Avoidance & Asynchronous Background Document Sync**:
  - **Trap**:
    Running disk scans and document synchronization (`syncAvailableDocuments()`) synchronously on the Main Thread in `AppModel.init()` blocks window rendering. Furthermore, calling SQLite queries (like `allTopics()`) inside nested loops over hundreds of documents or performing quadratic string comparisons across thousands of dummy topics causes multi-second UI freezing on app startup.
  - **Rule**:
    1. **$O(1)$ In-Memory Lookups**:
       Pre-fetch and cache topics and documents into `[String: Set<String>]` and `[String: String]` Dictionaries/Sets before running maintenance passes, reducing query complexity from $O(N^2)$ to $O(1)$.
    2. **Detached Asynchronous Startup Task**:
       Move `database.syncAvailableDocuments()` out of the synchronous `AppModel.init()` flow into a detached background task (`Task.detached(priority: .utility)`), dispatching any subsequent UI state reload back to `@MainActor`. Startup completes in milliseconds.

- **Bookshelf Thumbnail Generation Must NEVER Trigger Heavy Document Conversions (`existingConvertedPDFURL`)**:
  - **Trap**:
    In `DocumentCoverView.generateCoverThumbnail`, falling back to `try? EBookConverter.ensureConvertedPDF(for: url).pdfURL` when an EPUB or ebook lacked an extracted cover image triggered full document conversion (spawning Calibre's `ebook-convert` or WebKit rendering). When documents are located on remote network shares (SMB/NFS) or when multiple ebooks appear on the bookshelf, every item without a cover spawned external processes in parallel, pegs CPU at 100%, saturates network bandwidth, and causes the entire application to lag and freeze.
  - **Rule**:
    1. **Strictly Non-Converting Thumbnail Resolution**:
       Shelf thumbnail generation passes must NEVER run document format conversions. Use `EBookConverter.existingConvertedPDFURL(for: url)` which strictly inspects whether a converted PDF already exists on local disk.
    2. **Network Volume Guard**:
       On network shares without sidecar `.md5` files, avoid reading megabytes over SMB just to compute hashes for thumbnail checks; return `nil` immediately.
    3. **Graceful Card Cover Fallback**:
       When no thumbnail is cached or available, display the native document cover card featuring the document title, format badge (`EPUB`, `MOBI`, `AZW3`, `DOCX`, etc.), and icon. Format conversions are deferred strictly until the user actively opens the document to read it.

- **Topic Hijacking by Eager Topic Selection & Default `attachToTopic: true`**:
  - **Trap**:
    `reloadLibrary()` eagerly defaulted `selectedTopicID = topics.first?.id` even during normal bookshelf browsing. If topics were sorted alphabetically, any topic starting with a whitespace (e.g. `" Balkrishna M Sadekar..."`) became `topics.first`. When opening documents or manually triggering highlight imports with `attachToTopic: true` (the previous default), all cards and the document's MD5 were added into `selectedTopicID`, renaming or misattributing unrelated topics.
  - **Rule**:
    1. **Guard Eager Selection**: Only set `selectedTopicID = topics.first?.id` when `isInStudyWorkspace` is actively true, preventing bookshelf browsing from pinning background topic state.
    2. **Default `attachToTopic: false`**: Default `attachToTopic` to `false` when opening or picker-importing documents unless explicitly requested from inside an active study set.
    3. **Topic Matching & Auto-Repair**: In `handlePDFHighlightImport` and `openDocumentInReader`, match existing topics by MD5 or title before creating new topics, and auto-repair/rename single-book topics (`bookMD5List.count == 1`) whose titles mismatch `cleanDocTitle`.
    4. **Cascade Document Deletion**: When deleting a document, clean up `doc.md5` from all topics' `bookMD5List` and delete empty orphaned topics with 0 books and 0 cards.

- **Consecutive Highlight Merging with Footnote Links and Early Line Breaks (`isIgnorableBetweenText`)**:
  - **Trap**:
    Naive text checks between highlights rejected merging when highlights spanned across footnote link citations (e.g. `germs.[20] Scientists` or `cells.[21] Microorganisms`) or lines with early line breaks (ragged right margin with trailing whitespace/newlines). This broke large continuous highlights into fragments whenever a footnote number or line break occurred.
  - **Rule**:
    1. **`isIgnorableBetweenText(text:rect:on:)`**:
       Ignore whitespace, em/en-dashes, regex-matched footnote citations (`\d+`, bracketed numbers, footnote symbols `*`, `†`), and PDF link annotations covering the gap (`annot.type == "Link"`).
    2. **Line Break & Indent Geometry**:
       For multi-line highlights, check the rest of the previous line, the vertical gap, and the indentation of the next line using `isIgnorableBetweenText`.
    3. **Paragraph Preservation with `\n\n`**:
       When merging consecutive highlights across true paragraph boundaries, join the text using `\n\n` so paragraph breaks remain cleanly formatted inside the resulting note card.

- **Multi-Display macOS UI Automation & Negative Coordinate Traps**:
  - **Trap**:
    Secondary displays (e.g. AirPlay displays or extended monitors positioned to the left of the main screen) have negative coordinate origins (e.g. `X: -1711, Y: 50`). CLI tools like `cliclick` fail to parse negative coordinates, misinterpreting them as CLI flags or screen 0 coordinates, accidentally clicking Display 0 and disrupting user workflows.
  - **Rule**:
    Use AppKit's Accessibility API (`AXUIElementCreateApplication`, `AXUIElementPerformAction(..., kAXPressAction)`) to programmatically trigger buttons and UI actions without mouse click simulation or coordinate translation. When window movement is necessary, set `kAXPositionAttribute` directly via `AXValueCreate(.cgPoint, &pt)`. Always use `screencapture -D <displayIndex>` with the specific display index to inspect and verify secondary screens.

- **SwiftUI vs AppKit Font Metrics Mismatch in MindMap Card Height (`minimumLineHeight`)**:
  - **Trap**:
    SwiftUI `.font(.system(size: 11.5))` + `.lineSpacing(2)` spaces lines using `ceil(font.ascender - font.descender)` (14.0pt + 2.0pt = 16.0pt/line). AppKit's `NSAttributedString.boundingRect(with:options:)` without `minimumLineHeight` ignores font ascent/descent rounding and steps lines at ~15.0pt/line. On long multi-paragraph cards (e.g. 100+ lines in merged cards), this 1.0pt deficit per line accumulates to a 100+ point deficit. Because `TreeLayout` positions cards using `measureTextHeight`, underestimating card height causes consecutive cards to vertically collide and overlap in mindmap view.
  - **Rule**:
    1. **Enforce Minimum Line Height**: In `TreeLayout.measureTextHeight`, always configure `NSMutableParagraphStyle` with `let fontLineHeight = ceil(font.ascender - font.descender); if fontLineHeight > 0 { paragraphStyle.minimumLineHeight = fontLineHeight }`.
    2. **Safety Buffer**: Add a safety buffer (+8pt) to `estimatedCardHeight` to absorb subpixel antialiasing and padding variances.
    3. **Top Frame Alignment**: In `MindMapCanvasView`, specify `alignment: .top` for card `.frame(width: w, height: h, alignment: .top)` so card headers stay firmly pinned to the top of layout frames.

- **One Native Note vs Multi-Segment Cards in PDF Highlight Merging**:
  - **Trap**:
    When consecutive highlights are merged into a card, storing them as multiple `excerptSegments` causes `PDFReaderView` to render each segment with individual brackets, separate selection handles, and multi-highlight interaction states. Users expecting a unified native highlight note instead see multiple fragmented highlights joined together.
  - **Rule**:
    1. **User Choice via Sequential Alerts**: After the user selects "Merge Consecutive Notes", present a follow-up alert asking whether to merge into "One Native Note" (`singleNativeHighlight: true`) or "Several Highlighted Areas" (`singleNativeHighlight: false`).
    2. **Contiguous Rect Unification**: For `singleNativeHighlight == true`, merge overlapping or contiguous line rects across lines and pages into unified line rects via `PDFHighlightResolver.mergeContiguousLineRects(allRects)` and set `excerptSegments = []`.
    3. **Single Native Note Semantics**: When `excerptSegments` is empty, `card.effectiveSegments` produces a single unified `ExcerptSegment(id: id, text: highlightText, rects: highlightRects)`. In `PDFReaderView`, the entire merged text acts as a single continuous native highlight note with one set of handles and brackets.

- **Replacing Original PDF Highlight Annotations with App Native Highlights & Sidecar MD5 Invariant**:
  - **Trap**:
    When PDF highlights are turned into notebook cards, if the original PDF annotations (`Highlight`, `Underline`, `StrikeOut`) remain embedded in the PDF document, deleting a card or excerpt segment in MarginGraph removes the app's dynamic highlight but leaves the original PDF annotation permanently visible on the page.
    Furthermore, if original annotations are stripped and the PDF is saved to disk via `PDFDocument.write(to:)`, the file's raw byte SHA-256/MD5 changes. If `PDFDocumentManager` recomputes the MD5 from raw bytes upon the next application launch, all database linkages (`documents`, `topics`, `cards` matching `bookMD5`) break, orphaning all notes.
  - **Rule**:
    1. **Strict Distinction Between App & Original Annotations**: `PDFReaderView` paints dynamic card highlights with `contents = "MarginGraph-card-highlight"` or `"MarginGraph-card-emphasis"`. When detecting, counting, extracting, or deleting original PDF annotations, always filter out annotations where `annot.contents?.hasPrefix("MarginGraph-") == true`.
    2. **Strip Original Annotations on Import & Document Load**: When turning highlights into cards (or opening an existing document with cards), call `PDFHighlightImporter.deleteOriginalHighlights(from:extracted:docModel:)` to remove original highlight/underline/strikeout annotations from all pages in-memory and persist the cleaned PDF.
    3. **Guarantee Sidecar `.md5` Before Rewriting PDF**: Whenever saving a modified PDF to disk, ALWAYS compute/retrieve the authoritative document MD5 and write it to `<fileURL.path>.md5` (and `<fileURL.path>.pdf.md5`) *before* executing `document.write(to: targetURL)`. This permanently anchors document MD5 immutability and protects database integrity.
    4. **Failsafe Overlap Cleanup on Delete**: In `delete(cardID:)` and `deleteSegment(cardID:segmentID:)`, scan the `PDFDocument` for any lingering non-MarginGraph annotations intersecting the deleted card/segment's line rects, remove them from the page, ensure the sidecar `.md5` exists, and write the document to disk.

- **Document Switching Performance & Zero Synchronous Network Disk Writes**:
  - **Trap**:
    In `switchToDocument()`, calling synchronous disk operations like `PDFHighlightImporter.deleteOriginalHighlights(from:extracted:docModel:)` whenever a document was selected forced a full page-by-page annotation scan and synchronous `PDFDocument.write(to: targetURL)` on the main thread. When documents were hosted on external volumes or SMB network shares (e.g. `/Volumes/omv/backups/marginnote/main/...`), this stalled the main thread for 20-30 seconds on every document click.
  - **Rule**:
    1. **Zero Synchronous PDF Disk Writes on Document Open**: `switchToDocument()` must be instantaneous (< 500ms). Never invoke `PDFDocument.write` synchronously during document switching or reader loading. Stripping original annotations should be done asynchronously or specifically during highlight import operations.

- **Unconditional Synthetic Document Root Card Filtering Across All Libraries & TreeLayout Clamping**:
  - **Trap**:
    MarginNote creates a synthetic document root card for each imported book (e.g. "Ahrens_2017_How-to-take-smart-notes") with radiating links to hundreds of child notes. When `filterMarginNoteDocumentRootCard` was gated behind `if isExternalDatabase`, it was skipped when `isExternalDatabase` was false (such as during initialization or in the built-in library), displaying the synthetic card and 47+ radiating link lines. In multi-book topics, reachability across the entire topic was under 80%, causing the root card not to be recognized. Furthermore, in `TreeLayout`, arbitrary coordinate clamping (`explicitFirstY < 5000`) caused large topics where $Y \ge 5000$ (Ahrens spans $Y$ up to $67,600$) to reset their positions and overlap.
  - **Rule**:
    1. **Unconditional Root Filtering**: Filter synthetic document root cards unconditionally in all libraries (built-in and external) and whenever reloading study sets or document cards.
    2. **Multi-Book Topic Support**: Compute reachability per book (`bookCards`) as well as across the whole topic, iteratively stripping all synthetic root cards, promoting their children to roots (`groupNoteId = nil`), and purging root card IDs from `mindLinks` and `topicLinks`.
    3. **Remove Arbitrary Coordinate Clamping**: In `TreeLayout`, support arbitrarily large coordinate spaces ($Y > 20$, `.isFinite`) without artificial upper bounds.

- **Mandatory Pre-Commit Benchmark & Non-Overlapping Layout Verification**:
  - **Trap**:
    Performance regressions (e.g. network disk stalls on document open) and layout regressions (card overlaps or root card radiating lines) can silently creep into code changes if not verified before commit.
  - **Rule**:
    Two automated tests in `Tests/MarginGraphCoreTests/MindMapTests.swift` are mandatory before any commit:
    1. `testMandatoryBenchmarkDocumentOpenAndCardClickSpeed`: Verifies document opening (< 500ms) and card click responsiveness (< 100ms) with both mock data and real PDF documents.
    2. `testMandatoryMindMapLayoutZeroOverlapsAndRootIgnored`: Verifies that synthetic document root cards are pruned and that every pair of visible card bounding boxes in mindmap layout has zero intersections (0 overlaps) across both synthetic forest benchmarks and real library topics.
    No commit is permitted unless both tests pass cleanly.

- **Sparse Outlier Coordinates & Cohesive Column Layout in Imported MindMaps**:
  - **Trap**:
    In imported MarginNote databases, a document might have hundreds of cards with unassigned coordinates (`mind_x = nil`) and only a tiny handful of outlier cards with manual coordinates (e.g. 11 cards out of 678 cards with $X \in [702, 17678]$ and $Y \in [-96977, 122886]$). If `TreeLayout` clusters columns based on any existing finite $X$, it creates 10 single-card columns spanning 18,000 pixels, inherits extreme vertical offsets, and packs the remaining 667 cards past $X = 18000$.
  - **Rule**:
    1. **Cohesiveness Threshold for Explicit Columns**: Only cluster explicit columns when a significant portion of root cards have explicit coordinates (`rootsWithExplicitX.count == roots.count || ratio >= 0.35`). When explicit roots are sparse (< 35%), treat all roots as unpositioned and pack them into uniform vertical columns of `maxColumnHeight` (e.g. 900pt).
    2. **Reading Order Sorting**: In `TreeLayout.cardOrder`, prioritize document page order (`card.startPage`) when available, falling back to coordinate $Y$ and creation time.

- **Robust Synthetic Document Root Detection Without Arbitrary Reachability Thresholds**:
  - **Trap**:
    MarginNote synthetic document root cards (empty text cards created to anchor book title notes) do not always link to 80% of cards (in large books, a user may only link 47 out of 678 cards, resulting in < 7% reachability). An 80% reachability requirement fails to filter the root card, leaving the book title card with dozens of radiating cross-links.
  - **Rule**:
    Detect synthetic root cards using robust structural signatures: empty highlight & notes text, nil `startPage`, nil `groupNoteId`, no incoming parent/links, and either coordinate `(10000, 10000)` or high outbound links ($\ge 10$ links, or $\ge 5$ links reaching $\ge 5\%$ of same-book cards).

- **Defensive Canvas Viewport Validation Against Empty Canvas Coordinates**:
  - **Trap**:
    The SQLite `documents` table may store stale or out-of-bounds pan/zoom coordinates (e.g. `mind_pan_x: -1126.42, mind_pan_y: -873.58`) pointing to empty canvas space. Restoring these coordinates on document open displays an entirely blank canvas, requiring the user to manually zoom to fit.
  - **Rule**:
    In `MindMapCanvasView.applyInitialViewport`, validate that the restored viewport actually intersects at least one rendered card frame. If no card intersects the restored viewport, automatically trigger `viewport.zoomToFit(nodes: Array(frames.values))` so content is always immediately centered and visible.

- **Mandatory App Binary Rebuild (`swift build`) Verification**:
  - **Trap**:
    Running `swift test` only compiles test products; it does NOT update `.build/arm64-apple-macosx/debug/MarginGraphApp`. If the user or agent launches `MarginGraphApp` without running `swift build`, the app runs outdated code from a previous build and symptoms appear unfixed.
  - **Rule**:
    Always execute `swift build` (or `swift build --product MarginGraphApp`) after code changes before launching the application binary or declaring completion.



- **MindMap Card Transform and Layout Cache Ownership**:
  - **Trap**: Card `.position(...)` creates a parent-sized layout container around gestures. Mixing center-anchored scaling with top-aligned frames also shifts painted card bounds away from the canvas coordinates. Eagerly computing `TreeLayout.layout` in a `State(initialValue:)` argument repeats text measurement whenever SwiftUI reconstructs the view, even when retained state discards that value.
  - **Rule**: Use explicitly sized card frames, `.scaleEffect(..., anchor: .topLeading)`, a top-leading scaled frame, and `.offset` from `viewport.canvasToScreen(frame.origin)`. Pin the canvas stack to its viewport size. Initialize layout state cheaply, then compute it on appearance or card changes. Measure card heights once per layout pass and share them between packing and placement. Image height reservations must match the rendered thumbnail maximum (120 points). Verify long text sizing with actual `NSHostingView` measurements as well as frame intersection tests.

- **Native Computer Use Requires a Discoverable App Bundle**:
  - **Trap**: The native computer-use app resolver rejected the standalone SwiftPM `MarginGraphApp` executable by both name and path; it was absent from the app inventory.
  - **Rule**: Run `bash scripts/prepare-ui-test-app.sh` to build and wrap the executable in `.build/UITesting/MarginGraph.app` with a bundle identifier and `CFBundleExecutable`. Select the resulting absolute `.app` path through `cua.getApp`, then verify accessibility state and screenshots. Rebuild the wrapper after source changes; do not rely on a stale copied binary. This setup was verified by opening a shelf document and opening/dismissing the reader menu through computer use.

- **External Library Open Must Be Profiled Through the Full UI Path**:
  - **Trap**: Ahrens in the built-in library opened without the external library's long freeze. The UI-test bundle has separate preferences from the bare executable and initially selected a different library. Testing the existing `main/MarginGraph.sqlite` on the network volume reproduced an accessibility timeout around 18 seconds, with recovery observed by 27.5 seconds. A CPU sample showed the main thread blocked in `openDocumentInReader → switchToDocument → reloadLibrary → dueCardCountsByTopic → sqlite3_step → pread`, plus duplicate document-card reads through `switchToDocument` and `reloadStudySet`.
  - **Rule**: Verify the active database and document path before performance comparisons. Avoid full-library aggregate/review refreshes and duplicate card fetches on the document-open critical path, especially on network SQLite. The current mandatory open benchmark covers PDF construction and one card query, not AppModel opening, library refresh, or SwiftUI rendering; passing it does not establish live UI responsiveness. Distinguish computer-use observation overhead from app timing and profile the complete user interaction before claiming a performance fix.

- **Document Recency Updates Must Not Reload Whole Libraries**:
  - **Trap**: `openDocumentInReader` and `switchToDocument` refreshed the entire library for recency-only changes, repeatedly computing review aggregates on network SQLite. `reloadDocumentCards` also re-read all matching cards even though the active notebook already owned its cards. Prefix OR predicates applied directly to card rows forced full table scans of large card bodies.
  - **Rule**: Update document/topic recency in one transaction and mirror those fields in the loaded model arrays. Reuse loaded topic counts for notebook matching and topic cards for notebook document rendering. Keep full library refreshes for actual library changes. Resolve compatible hashes with an index-only subquery before fetching matching card rows; retain exact and both prefix directions. Verify with `EXPLAIN QUERY PLAN` and prefix/cross-topic regression tests. In live external `main` testing, the previous 18-second inspection timeout disappeared: first-open observation completed in 2.8 seconds, reopen in 2.6 seconds, and tab switching in 1.5 seconds (all include computer-use overhead, not app-only benchmark durations).

- **Study Notebook Covers Must Load Outside View Rendering**:
  - **Trap**: The external library Study grid repeatedly checked network file existence while matching documents, then synchronously opened PDFs and rendered cover thumbnails in `NotebookCardView.body`. A main-thread sample showed PDF opening and thumbnail generation dominating the freeze; accessibility inspection repeatedly timed out.
  - **Rule**: Match notebooks using loaded document metadata without filesystem probes. Load covers on a serial background queue and cache both successful and unavailable results across notebook views. Publish images on the main queue only when the view still requests that path. Never perform PDF or network filesystem work in SwiftUI `body`. Live external-library testing showed the Study grid appearing in 1.4 seconds including computer-use observation overhead, with responsive scrolling; this is not an app-only benchmark measurement.

- **Document Routing Must Use Book Ownership and Honor Explicit Detachment**:
  - **Trap**: Opening a document combined attachment, card-hash, and fuzzy-title candidates, then selected the largest notebook by total card count. A large Ahrens notebook with a stale Rock attachment won over Rock's own cards. Opening also renamed the chosen notebook and reattached the book; deleting an attachment could be reversed by card/title fallback on the next open.
  - **Rule**: Rank candidates by matching document-card counts before attachment and exact title evidence, with deterministic ties. Never rename a notebook as a side effect of opening a document. Persist explicit topic/document exclusions (schema version 4) and honor them both in routing and document-list fallbacks; explicit attachment clears the exclusion. Remove compatible prefix attachments and stale last-document state when detaching. Regression tests must cover a larger unrelated notebook, stale in-memory candidates, card/title fallback after detachment, and explicit reattachment. Live external main testing verified Rock's PDF and its own notebook content on initial and repeated opening, with Manage showing only Rock.

- **macOS Privacy Approvals Depend on Code Identity**:
  - **Trap**: The SwiftPM UI-test wrapper originally inherited an ad hoc executable signature whose designated requirement was only a cdhash. A stable bundle identifier alone does not preserve privacy approval across executable rebuilds. Separate file locations may legitimately prompt separately.
  - **Rule**: Sign and verify the full bundle using a consistent certificate-backed signing identity; the preparation script accepts MARGINGRAPH_SIGNING_IDENTITY and detects installed Apple development/distribution identities. Clearly report ad hoc fallback and the absence of a local certificate. Never weaken designated requirements to identifier-only matching or edit TCC grants. The unchanged bundle was restarted and its external network library reopened without a prompt. The sandboxed identity inventory initially reported no certificates, but the escalated build found an existing Apple Development identity and successfully verified a certificate-backed bundle requirement; inspect signing in the same keychain access context as the actual build.

- **Other-App Container Consent Is Not Ordinary Folder Permission**:
  - **Trap**: The user observed recurring “data from other apps” prompts even after approving all prompts and after certificate-backed signing. Apple documents container consent that lasts only for an app instance. The app launched a filesystem synchronization of every built-in document, even when the user intended an external library, and cover rendering read files from other apps’ containers. App-only accessibility observations did not reveal the system privacy dialogs; an apparently responsive app tree was not evidence that no prompt appeared.
  - **Rule**: Do not promise stable signing persists other-app container consent. Load catalog metadata on launch without automatic filesystem synchronization (which can also misclassify denied access as missing files and delete catalog entries). Avoid filesystem/cover probes of Library/Containers and Library/Group Containers during shelf and notebook rendering. Preserve explicit opening of those documents, which may legitimately require consent each session. Stable signing still matters for ordinary folder approvals across builds. Verify launch behavior with system-dialog visibility and incorporate user observations.

- **Preserve Covers with Durable Local Preview Storage**:
  - **Trap**: Skipping thumbnail generation for all protected-container paths hid existing book covers, including Ahrens. That was a user-visible regression, not an acceptable permission fix.
  - **Rule**: Shelf and notebook loaders must read locally persisted preview images before checking or opening the source. On a cache miss, generate the cover asynchronously and atomically save a PNG in MarginGraph/CoverThumbnails. Hash source path plus rendering variant to isolate libraries and sizes. A first generation can need macOS consent; later launches must load the preview without a source stat. Keep filesystem synchronization off the startup path. Do not replace functioning covers with permanent placeholders to suppress prompts.
  - **Verified**: After the user approved initial protected-source access, Ahrens's cover appeared and a 24,655-byte shelf PNG was saved. Quit/relaunch preserved the visible cover on the built-in bookshelf. The full 201-test suite passed, including a cache test that loads an image with an unavailable source path. This verifies cover persistence, not permanent permission to open the protected PDF itself.

- **Mind Map Overview Belongs to the Viewport**:
  - **Trap**: The overview defaulted to collapsed and participated in the canvas content stack, whose layout can grow as zoomed cards extend beyond the viewport. Controls aligned within that content can move outside the clipped visible pane.
  - **Rule**: Initialize overview visibility as expanded. Place expanded overview and collapsed reopen button in a bottom-trailing overlay on the explicitly sized viewport, independently of card geometry and zoom. Only the close/reopen buttons change visibility. Live external Rock testing verified initial expanded display, visibility after repeated zoom-in, close to a contained reopen button, and reopening at the zoomed viewport. Both mandatory benchmark/layout tests passed.

- **Direct Working Databases Need Original Attachment Sources**:
  - **Trap**: Opening an external MarginGraph.sqlite directly cleared media fallbacks, although document paths still pointed into a MarginNote backup. Card image hashes were present but their files were only in the original MarginNotes.sqlite.files directory. The Prefrontal Cortex attachment was a 1120×945 PNG named by its hash, not an inline ZMEDIA blob.
  - **Rule**: When opening a working database directly, derive backup package roots from its retained document paths and reconnect their media directories and original SQLite fallback. Keep deterministic root ordering and clear old database handles before changing sources. Live external Rock verification confirmed the brain image renders inside the Prefrontal Cortex card. Both mandatory benchmark/layout checks passed.

- **Imported Child Maps Are Anchor Branches, Not Separate Topics**:
  - **Trap**: MarginNote stores Child Map 0 as an empty map-anchor card in the same topic, with ZMINDLINKS pointing to Your Brain. Prefrontal Cortex is reachable below that root. Imported anchors and links already existed, but the canvas laid all topic cards out together and hard-coded Main MindMap in its header.
  - **Rule**: Detect child-map anchors and partition their reachable branches from the main layer. Project ordered mind links into a cycle-safe display hierarchy while retaining explicit group parents and preserving stored cards. Use the same projected cards for layout and tree connectors. Selecting a card routes to its owning child map; provide a contained layer selector for manual switching. Live external Rock verification displayed Child Map 0, the connected Your Brain hierarchy, and Prefrontal Cortex with its image. Full 202-test suite passed, including ownership/partition/hierarchy/cycle regression and both mandatory checks. This reconstructs hierarchy with MarginGraph's layout rather than promising pixel-identical MarginNote coordinates.

- **Balance Automatic Mind Maps by Measured Content Area**:
  - **Trap**: A column-height heuristic based only on card count produced very different overview proportions for books with short notes versus long excerpts. Translucent overview backgrounds also allowed unrelated canvas text to show through.
  - **Rule**: Size automatic column packing from measured subtree heights and widths with a consistent 3:2 target. Preserve complete branches and explicitly positioned columns; do not stretch individual cards to force every hierarchy to the same shape. Keep the fixed-size overview background opaque. Regression coverage must compare different excerpt lengths and assert both reasonable aspect ratios and zero intersections. Live external Rock and Ahrens testing verified denser, contained overviews and PDF rendering; the reader More menu remained within the window. All 203 tests, including both mandatory pre-commit checks, passed.

- **Sanitize Export Suggestions Before Presenting NSSavePanel**:
  - **Trap**: Package contents sanitized filenames, but document/folder save-panel suggestions interpolated raw titles. macOS displayed a title colon as a slash in the save field.
  - **Rule**: Reuse MarginPackageExporter.sanitizeFilename for both document and folder default export basenames before adding the timestamp and extension. Live verification for Homo Deus showed Homo Deus_ A Brief History of Tomorrow with its timestamp and .marginpkg extension; cancel the dialog to avoid an unnecessary export. All 204 tests passed, including both mandatory checks and slash/colon regression coverage.

- **Package Round Trips Do Not Establish MarginNote Notebook Compatibility**:
  - **Trap**: MarginGraph could reimport its exported notes by topic ID, but the package omitted ZTOPIC.ZMINDLINKS entirely. The native reference package enters its notebook through an anchor note with ordered mind links. Exported BookConfig titles also used display titles rather than packaged PDF basenames, and all exports reused the template's Core Data store UUID.
  - **Rule**: Export a stable notebook root linked from each topic, connect retained hierarchy children, assign missing coordinates, serialize mind positions as comma-separated pairs, and remove references to unexported cards. Scope book lists to included documents and use file basenames in BookConfig. Generate a fresh store UUID and exclude resource-fork ZIP entries. Test native SQL relationships independently of MarginGraph's forgiving importer, as well as round trips. Live Homo Deus export retained 224 original cards plus its root, all 225 positions, no dangling links, and passed SQLite integrity checking; document/PDF/map and contained reader menu were also exercised. All 204 tests and both mandatory checks passed. The user's macOS MarginNote license is read-only, so native notebook import was not verified; structural comparison must not be reported as successful MarginNote import.

- **Native Highlight Archive Types and EPUB Source Preservation**:
  - **Trap**: The user reported a MarginNote import crash after the notebook-root fix. Comparing the reference package's binary plists revealed that ZHIGHLIGHTS is an NSKeyedArchiver NSMutableArray of NSMutableDictionary records, with gzip-compressed JSON textSelData containing typed CGRect objects. Our exporter wrote a dictionary root with textSelLst; the forgiving MarginGraph importer accepted this incompatible shape. Synthetic roots also incorrectly received page 1 and brace-wrapped start/end coordinates differed from the reference. Converted EPUBs were packaged from their hash-named cached PDFs.
  - **Rule**: Match the native highlight archive container types and gzip textSelData representation; validate decoded archive roots independently of our importer. Keep absent pages SQL NULL and serialize positions as comma-separated pairs. For converted EPUBs, resolve the original source_path and package the actual EPUB under a sanitized display-title filename. Fail explicitly when the original source is missing, and propagate copy errors. Do not attach cached-PDF page rectangles to an original EPUB: retain notebook text while omitting those invalid navigation anchors. Use matching readable basenames in BookConfig.
  - **Verified**: Fresh live exports contained all 224 Homo Deus highlights in native array/gzip form and the Short Stories source EPUB byte-for-byte under its proper name, without a cached PDF. Both databases passed integrity checking. The app's PDF, mind map, and contained reader menu were exercised. All 205 tests and both mandatory pre-commit checks passed. Native iOS import/crash resolution remains unverified because macOS MarginNote is read-only; the archive-type mismatch is a concrete compatibility defect, not a confirmed crash stack diagnosis.

- **Exact Native Package Round Trips Require Retaining the Whole Archive**:
  - **Trap**: Reconstructing a MarginNote package from normalized MarginGraph models drops native notebook settings, unknown fields, archived object payloads, and media metadata. SQL integrity and our importer round trips did not establish compatibility. The user required byte-identical exports of three native references. Ahrens also contains two book-config records but only one bundled PDF; the single-extracted-file fallback incorrectly assigned that PDF to Rock as well, causing identity migration during deduplication.
  - **Rule**: Schema version 5 retains original .marginpkg bytes with a snapshot of relevant document content, topics, cards, and links. Export the retained bytes only while that state is unchanged. Ignore recency/viewport changes and canonicalize unordered book attachment lists; actual content edits invalidate reuse. Do not retain a merged package when extra cards or remapped topic identity make it a different notebook. Restrict the single-file document fallback to a single book record, and open a physical imported document rather than a placeholder. Tests must verify whole-file byte equality, not just selected fields, and verify an edit invalidates reuse.
  - **Verified**: With user approval to replace the matching notebooks (a recovery database snapshot was saved first), reimported Ahrens, Adler, and Save the Cat through the built-in library UI. Restarted, switched back to built-in, and exported all three through the shelf menus. Every output matched the original ZIP byte-for-byte, SHA-256 and every archive entry included. The live test exposed attachment-list reordering as a false invalidation; canonicalizing it fixed the real path. PDF/mind map and reader More-menu containment were verified in the final build. All 207 tests and both mandatory checks passed. Exact preservation applies to unchanged imported packages; newly authored or edited notebooks still use reconstructed export and their native MarginNote compatibility is not established by this result.

- **Keep Native History State Separate from Recency**:
  - **Trap**: Reconstructed exports populated ZTOPIC.ZHISTORYDATE with topic.updatedAt. The user reported Homo Deus importing without a crash but being marked archived, whereas byte-preserved Adler was editable. All three native reference packages leave ZHISTORYDATE NULL; our exporter had conflated this distinct field with recency.
  - **Rule**: Leave ZHISTORYDATE NULL for active reconstructed notebooks. Store recency in ZLASTVISIT and creation in ZDATE; do not invent history state from local modification dates. Retained original archives remain byte-identical.
  - **Verified**: Regression assertions cover NULL history and present creation/visit dates. A fresh built-in-library UI export of Homo Deus contains NULL history, all 224 notes plus its root, and passes SQLite integrity checking. PDF/map rendering and reader-menu containment were exercised. All 207 tests and both mandatory pre-commit checks passed. Native iOS editability remains unverified locally; do not equate metadata correction with a confirmed native import result.

- **Native Document Identity, Book Roots, and Palette Are Export Contracts**:
  - **Trap**: Homo Deus imported as an editable notebook, but its document/notebook navigation was detached. The reconstructed package reused a local 32-character hash for ZMD5LONG and omitted ZFORUMOWNER.bookGroupNotes. The bundled PDF's native identity differed. Native color index 7 is red, whereas MarginGraph uses it for teal; concatenating decimal color indices also breaks native hexadecimal suffixes above 9.
  - **Rule**: Compute the native sampled-file identity from the staged original document and remap export-only BookConfig, topic attachment, card book hash, and bookGroupNotes keys consistently. MarginNote's BookMd5FromFileHandle uses MD5 of the bytes before its 64 KiB chunk boundary (61440 bytes for large files), then MD5 of the last 8192 bytes followed by 8192 bytes centered at file midpoint. Files below 65536 bytes use their complete MD5 twice. This was checked against the installed native implementation and reproduced Adler's stored 64-character identifier exactly; it is not SHA-256. Map each book to its own existing root note, including separate book anchors for multi-document notebooks. Do not mutate local catalog identity. Map local palette hues to native indices and encode hexadecimal suffixes. When excerptSegments exist, archive separate native selection records within one merged card instead of flattening their text and rectangles into one selection. Existing cards without stored segment boundaries retain their combined excerpt and rectangles.
  - **Verified**: Fresh built-in Homo Deus UI export retained 224 excerpts plus its root; an independent sampled-hash calculation matched the packaged PDF, BookConfig, topic, all cards, and root mapping. Its 61 teal cards now use mbooks-annotationa. Tests cover hash fixtures, short-file identity, native root metadata, multi-document root/card ownership, merged selections on different pages, and hexadecimal colors. All 208 tests and both mandatory checks passed. Live document/card navigation, PDF/map rendering, export, and reader-menu containment were exercised. Native iOS navigation remains unverified locally because the macOS installation is read-only; do not claim successful native navigation from these structural checks alone.

- **PDF Highlight Resolution Must Use the Editable Toolbar Palette**:
  - **Trap**: PDF color resolution searched all 16 rendering colors and assigned teal (7) and pink (8), although document/mind-map note toolbars expose only the first six swatches. Imported cards could therefore use colors unavailable in their normal editing controls.
  - **Rule**: Resolve extended source hues into the six primary toolbar colors before document-wide matching: teal/aqua to blue (2), pink to coral (3), and indigo to purple (4). Restrict distinct cluster assignments to six colors and use primary-palette fallback for additional clusters. Keep legacy extended rendering support for existing native content; avoid a destructive blanket recoloring of all stored notes.
  - **Verified**: Updated individual-color coverage and added a document-cluster regression asserting teal resolves to blue with all results in 0..<6. All 209 tests and both mandatory checks passed. The user-identified Homo Deus card was recolored through the third toolbar swatch and SQLite confirmed color_index=2. After rebuilding and restarting, live selection showed that swatch selected and the corresponding PDF excerpt blue; PDF/map rendering and contained reader menu were verified.

- **Import Sources Are Read-Only; Destructive Shelf Actions Require Confirmation**:
  - **Trap**: The plain-file import path built a PDFDocumentManager directly from the user's URL, stored that path, then PDFHighlightImporter persisted annotation cleanup to it. The original PDF lost its notes. A single shelf More-menu Delete also invoked database deletion immediately.
  - **Rule**: Stage plain imports in the active library's ImportedDocuments directory before loading/conversion or mutation. Use a unique subdirectory to preserve readable filenames without overwriting earlier imports; copy identity sidecars only into managed storage. For manual highlight import of legacy externally referenced PDFs, copy and reload the working PDF before cleanup and update the stored document path. Propagate staging failures visibly instead of falling back to writing the source. Resolve the canonical document after insertion to respect deduplication. Single-document shelf deletion must open a window-attached confirmation alert that names the document and notes affected, with Cancel as the Return/default action; only its destructive button invokes deletion.
  - **Verified**: Regression coverage imports annotated synthetic PDF bytes into a managed copy, converts highlights using in-memory SQLite, and asserts the source bytes/annotations remain intact, sidecars appear only beside the copy, and repeated imports cannot overwrite earlier copies. All 210 tests and both mandatory checks passed. Live import of the user-provided second Homo Deus PDF detected 892 highlights and created 226 merged cards; the catalog points inside ImportedDocuments. The source SHA-256 and modification time remained identical, with no new source sidecar, while the managed PDF changed. Card navigation, PDF/map rendering, and reader-menu containment worked. Clicking shelf Delete displayed the named confirmation sheet; Return cancelled it and the document plus 226 cards remained visible.

- **Exported Root Branch Defaults Must Match Native Framework Metadata**:
  - **Trap**: Reconstructed exports wrote ZZINDEX=0 for every card, so generated notebook roots defaulted to Tree. The user-provided Adler package's book root has ZZINDEX=4096 for its Framework setting.
  - **Rule**: Set ZZINDEX=4096 on generated notebook and per-book roots; leave ordinary cards at zero. Keep unchanged retained archives byte-identical. Assert native SQL root metadata separately from round-trip parsing.
  - **Verified**: All 210 tests passed, including both mandatory pre-commit checks and assertions for root 4096 versus ordinary-card zero. Fresh app UI export of Homo Deus confirmed root 4096 and SQLite integrity. PDF/map rendering and contained reader More menu were checked. Native MarginNote branch-setting UI was not verified locally because its macOS license is read-only.

- **Title-Only Card Frames Must Match Their Visible Headers**:
  - **Trap**: Title-only cards rendered a compact header but TreeLayout reserved at least 70 points and extra bottom padding. Connectors correctly used frame.midY, which fell below the visible vertical-edge center.
  - **Rule**: For nonempty title-only cards, reserve exactly the measured header height, including header padding. Do not apply body minimum heights or body safety padding to these cards. Preserve midpoint-based connectors and test layout frames against actual NSHostingView fitting heights for single-line and wrapped titles.
  - **Verified**: All 211 tests passed, including both mandatory performance/layout checks and the rendered-height regression. Fresh live external Rock Child Map 0 showed centered connections for Simplify, Choose, Chunk, and the wrapped concept card. PDF rendering and reader More-menu containment/dismissal were also checked.

- **Imported Note URLs Are Text References with Separate Display Labels**:
  - **Trap**: MarginNote stores references as a marginnote3app://note/UUID URL followed by blank lines and the linked title. Rendering that text literally exposed URLs and offered no navigation or editing.
  - **Rule**: Parse native URL/title references and Markdown note links without altering stored text on display. Render attributed hyperlinks through the app's internal deep-link handler, route selection to the target map layer and center the card, and show an unavailable-note message for missing destinations. The contained Note Links sheet edits title/destination and supports addition/removal using UTF-16 ranges applied from the end. Save through the existing card-update/undo path. Measure the displayed title rather than hidden URLs. Derive deduplicated text-reference edges only from cards in the same notebook and active map layer, and render grey dashed arrows in the connector canvas behind opaque card surfaces.
  - **Verified**: All 215 tests passed, including native/Markdown parsing, Unicode-safe create/update/delete database persistence, edge filtering/deduplication, and both mandatory pre-commit checks. Fresh external Rock UI displayed Basal Ganglia as blue underlined text; clicking it selected/centered the linked card and navigated its PDF passage. Dashed arrows were visibly obscured by intervening cards. The bounded editor's add/remove/title/destination/search/validation and Cancel flow were exercised without saving test edits to existing library content. Reader More menu containment and dismissal were checked. Saved CRUD is covered by in-memory tests; live save/undo was not completed after the user changed app state.

- **Linked Mindmaps Need Independent Preview Navigation State**:
  - **Trap**: Calling the main deep-link handler from a card hyperlink replaced the user's current selection and viewport immediately, preventing browsing references in place.
  - **Rule**: Card hyperlinks open a window-attached mindmap preview loaded from the destination's owning notebook. Keep cards, selected note, layer, fold state, viewport, and center requests local to the preview; expand destination ancestors locally. Follow further references inside that preview. Only the explicit Open in Main MindMap button invokes main-workspace navigation. Reuse the canvas for pan/zoom/layers and render the sheet within the main window's minimum dimensions. Closing must preserve the main map/PDF position.
  - **Verified**: All 215 tests passed, including both required benchmark/layout checks. Fresh external Rock testing opened Basal Ganglia centered in Child Map 0, followed Automatic habit within the popup, panned and zoomed to 120%, returned to the original linked note, and closed with the underlying map/PDF unchanged. Reopening and pressing Open in Main MindMap dismissed the popup and centered/selected Basal Ganglia in the main canvas. Popup controls and reader More menu were visually contained; reader menu dismissal worked.

- **Reference Lines Use Quiet Center-to-Center Geometry**:
  - **Trap**: Reusing curved branch geometry and dark edge arrows made note references compete with the hierarchy.
  - **Rule**: Reference links use a straight path from source frame center to target frame center, light grey at 35% opacity, and a 1.5-point dashed stroke. Draw them behind cards, including their endpoints; omit edge arrowheads. Branch connectors retain their hierarchy geometry.
  - **Verified**: All 215 tests and both mandatory checks passed. Fresh external Rock Child Map 0 displayed lighter straight reference lines passing behind intervening cards. PDF/map rendering and reader More-menu containment/dismissal were checked.

- **Directed References Need Visible Markers and Separate Collinear Paths**:
  - **Trap**: Straight center-to-center references overlapped when cards were collinear, and hidden center endpoints removed visible direction cues.
  - **Rule**: Draw references at 20% grey opacity with a 1.2-point dash stroke. Put a slightly stronger arrow on the approach to the destination, outside its rectangle and oriented toward it. Give overlapping collinear references deterministic parallel offsets with short straight joins to card centers. Use a canonical direction so reciprocal references separate consistently, and keep the paths behind cards.
  - **Verified**: All 217 tests and both mandatory checks passed. Geometry regressions assert distinct lane heights, preserved center endpoints, visible arrows outside target rectangles, and reverse-direction arrows. Fresh live Rock main map and Basal Ganglia popup showed faint separated reference paths and destination markers behind cards. PDF/map rendering, contained popup controls, and reader More menu containment/dismissal were checked.

- **Keep Structural Work Out of Mindmap Pointer Updates**:
  - **Trap**: Each drag update could re-project the active layer, scan parent relationships, parse text links, regenerate all reference geometry, and repeatedly traverse descendants while checking drop targets. Plain display text also built attributed strings unnecessarily.
  - **Rule**: Cache layer cards, ID/parent indexes, text-reference edges, and resting reference geometry when their inputs change. Recompute only reference paths incident to the moving card during dragging. Build a cycle-safe descendant exclusion/drop-target index once per gesture, throttle hover checks while keeping card movement immediate, and always resolve the final drop from the final gesture translation. Clear transient state and restore cursor rectangles on completion. Reuse compiled link regexes and return plain text directly when it has no note URL.
  - **Verified**: All 219 tests passed, including both mandatory pre-commit checks. A 1,200-card workload completed 600 hit-test/plain-text queries in approximately 50 ms; cycle/descendant exclusion has separate coverage. Fresh signed app testing used external Rock Child Map 0: main-canvas drag/drop and one Undo (Undo then disabled, Redo enabled), popup card dragging, pan/zoom, layer selection, PDF/map rendering, and contained reader More-menu opening/dismissal. These UI checks do not establish an exact frame rate.

- **Viewport HUD Layout and Drawing Must Be Independent of Map Extents**:
  - **Trap**: Bottom-left mode/zoom controls participated in the content ZStack's ideal size. Large scaled cards could enlarge that stack and push bottom-aligned controls below the pane. Pan/zoom also regenerated branch paths, transformed each path, recomputed scrollbar bounds, rebuilt the overview's colored card drawing, and recreated NSImage display objects.
  - **Rule**: Put the compact bottom-left HUD in a bottom-leading overlay on the explicitly sized viewport, as with the overview. Cache resting branch paths and content bounds on layout changes; update only branches incident to a dragged card. Cull by path bounds (not endpoint visibility, since a branch may cross the viewport with both endpoints offscreen). Transform the GraphicsContext once and compensate stroke/dash widths for zoom. Isolate static overview cards in an Equatable view without viewport dependencies. Cache successful display images by content hash per MediaStorage with an eviction limit; do not cache failed loads.
  - **Verified**: All 221 tests passed, including both mandatory benchmark/layout checks. Regression coverage checks crossing/offscreen branches, moving endpoints, hidden branches, and display-image object reuse. Fresh signed external-library UI testing opened Ahrens and Rock, exercised drag/drop plus Undo, panning, zooming, mode toggles, layer selection, PDF rendering, and reader More-menu containment/dismissal. Bottom-left controls remained anchored and clickable at 35%, 50%, 100%, and 172%. Rock Child Map 0 retained centered branches, dashed references/arrows, the Prefrontal Cortex image, and the overview. A computer-use timeout recovered; a subsequent CPU sample showed the main thread idle, so tool timings are not app frame-rate measurements.


- **Suppress PDF Footer Numbers in Both Selection Geometry and Extracted Text**:
  - **Trap**: Cross-page PDFKit selections include isolated footer numbers. Hiding their pixels alone leaves them in copied excerpts, while deleting digit strings from selected text can remove legitimate body numbers.
  - **Rule**: Detect number-only footer lines from each complete page, limited to its displayed bottom margin, and reject numeric fragments that share a row with other text. Cache detection lazily per page/document. Subtract the detected character ranges before deriving both highlight rectangles and normalized text, including handle drags, word selection, and marquee text. Render reversible masks in the existing mouse-transparent view overlay; never rewrite source PDFs or change crop boxes/annotations for this preference. Store the toggle by document identity. Keep utility controls fixed within narrow panes and let annotation tools scroll horizontally.
  - **Verified**: All 223 tests passed, including both mandatory pre-commit checks. Synthetic coverage checks three-page forward/reverse selection, Arabic/Roman/decorated footer formats, retained body numbers/footnotes, footer-only rejection, restoration, crop origins, document cache isolation, and unchanged PDF content/annotations. Fresh signed external Rock UI testing hid/restored footers, selected across pages 10–11, and copied/pasted the result into reader search: the paragraph joined without the intervening 10. Reopening Rock retained Hidden while Ahrens remained Visible. PDF/map rendering, scrolling/resizing, and reader More-menu containment/dismissal were verified at wide and narrow pane widths. Detection requires a text layer and an isolated recognizable footer number; stored-note cleanup and export behavior are covered by the following rules.


- **Export Footer Settings into the PDF Content, Then Recompute Package Identity**:
  - **Trap**: Reader masks, white annotations, and clipped Quartz redraws can hide footer pixels while leaving their text selectable in other PDF readers. Returning a retained original archive also bypasses the current document setting. Changing staged PDF bytes without updating the native sampled hash detaches the package notes from their document.
  - **Rule**: Keep the source PDF unchanged. When suppression is enabled, rewrite detected footer text-show operands in the staged PDF, preserving page coordinates, text/vector content, resources, annotations and navigation; add permanent content fills for image-backed footer pixels. Validate extracted text on every page before writing, and fail clearly for unsupported content rather than silently exporting selectable footer text. This formatting feature is not a security-redaction API. Handle split content streams and shared forms per invocation; PDF text matrices are not restored by q/Q. Bypass retained-archive export when transformation is requested, compute native identity from the final staged bytes, and remap all package references consistently. Snapshot each document's preference for folder exports. Run package generation off the main thread with an in-window progress overlay.
  - **Verified**: All 227 tests passed, including both mandatory performance/layout checks. Coverage includes selectable footer removal, retained body numbers and coordinates, shared forms, metadata/link preservation, original-byte preservation, visible-setting restoration, retained-archive bypass, mixed folder settings and atomic failure. Fresh signed external Rock UI testing exercised PDF/map rendering, the contained reader More menu, and an actual package export with progress feedback. Its PDF opened in Apple Preview with the footer absent; the 288-page rewrite passed full-page text validation. The exported notes database passed integrity checking and all 842 note records used the rewritten PDF's independently verified native identity. Native MarginNote import was not exercised. Detection still requires an isolated recognizable footer in a text layer; unsupported text layouts, encrypted PDFs and inline images on affected pages currently produce an export error.


- **Existing Footer Highlights Require Stored Note Repair, Not a Larger Pixel Mask**:
  - **Trap**: Hiding a footer left the padded edge of old highlight rectangles visible, and already-created cards still contained the footer digit between paragraphs. Exporting cleaned PDF bytes alone left the note text and selection records unchanged.
  - **Rule**: When hiding numbers (also when opening a document already set to Hidden), clean document-owned notes using detected PDF footer geometry and uniquely matched surrounding excerpt text. Never blanket-delete digits or reconstruct user prose. Remove entire padded footer-only rectangles, filter affected block selections, update segment text/rectangles and emphasis geometry, and preserve note/segment identities, titles, comments and unrelated body text. Skip ambiguous edited text and image excerpts. Scan a separate PDF instance off the main thread; compare original cards before committing to avoid overwriting concurrent edits. Persist the batch transactionally with one Undo/Redo action. Run the same cleaner on export-only copies so unopened documents export clean notes too. Showing page numbers restores their display, not the obsolete stored highlights; Undo restores the cleanup.
  - **Verified**: All 229 tests passed, including both mandatory benchmark/layout checks. Regression tests cover three-page Arabic/Roman/decorated footers, padded rectangles, merged segments, preserved user edits/body numbers/comments, ambiguous and footer-only excerpts, idempotence, in-memory persistence/restoration, and cleaned package note text. Fresh signed built-in Homo Deus UI testing repaired the exact reported “from 6 eating” note to “from eating” and removed its green footer rectangle. SQL confirmed both text and geometry; one Undo restored both, and Redo cleaned them again. Visible mode showed an unhighlighted 6, Hidden removed it, and clicking the remaining paragraph selected the cleaned card. PDF/map rendering and reader More-menu containment/dismissal were verified. A stale running executable initially survived a shortcut quit; explicitly quit through its app menu and verify the loaded executable inode matches the rebuilt bundle when UI results contradict the new code.


- **Replace Must Retire Unused Predecessor Documents in the Same Transaction**:
  - **Trap**: Notebook Replace deleted cards/topics but left the old document row. A package PDF with a different content hash and a filename-sanitized title (`:` versus `_`) bypassed title/path deduplication, leaving two shelf entries. Conflict handling also mutated earlier notebooks before later prompts could return Cancel.
  - **Rule**: Collect all conflict decisions before mutating the catalog. Apply replacements, merges, note/link/review writes and predecessor retirement in one transaction. Identify predecessor documents from the replaced notebook's book/card identities, not fuzzy title equality. Retire only when an incoming replacement document exists and no remaining cards, notebook attachments or last-document references use the predecessor. Keep its PDF and bookmarks; record retired paths in the library database so filesystem discovery cannot resurrect them. Explicit import clears that path's retirement. Preserve incoming replacement hashes rather than letting same-title insertion adopt an old shared identity. Automatic same-title synchronization must likewise preserve distinct documents still referenced by notes/notebooks. Return canonical applied topic/document identities to the caller.
  - **Verified**: All 232 tests and both mandatory benchmark/layout checks passed. New in-memory regressions cover sanitized-title replacement, unchanged source bytes, no rediscovery, explicit restoration, shared PDFs with identical titles, later-prompt Cancel and transaction rollback on invalid cards. The existing Homo Deus orphan entry had zero cards and no topic references; it was removed after a full library backup, preserving the surviving 231 notes and both physical PDFs. Fresh signed app testing showed exactly one Homo Deus bookshelf item, opened its PDF and mind map, verified the reader More menu remained inside the window, dismissed it, and returned to the single shelf entry. Replacement transaction behavior is covered by automated tests; the user's notebook was not reimported during UI verification.

## PDF Export Graph Depth and Tokenizer Cost
- **Trap**: Recursively serializing a PDF object graph can overflow the roughly 544 KB stack of a `Task.detached` worker, even with cycle detection. Long outline `/Next` chains, destinations, arrays, and page `/Parent` references create deep valid paths. The Homo Deus crash report showed this exact stack-guard failure in `PDFObjectWriter`.
- **Rule**: Reserve object IDs and enqueue dictionaries, arrays, and streams, then drain the queue iteratively. Keep identity deduplication and finalize page overrides before serialization. Regression-test long linked graphs on a detached worker, including backwards links, destinations, and preserved outline labels. Bound recursive content-operand nesting separately.
- **Trap**: Constructing arrays and calling generic `contains` for every PDF byte/token dominated debug export CPU time. Parsing every text operand as a number and materializing nested array members also wasted work.
- **Rule**: Use allocation-free byte switches for lexical classification, parse numeric operands only for relevant operators, and scan nested operands without creating unused strings. Preserve all-page extracted-text validation; faster exports must still remove footer text while retaining body text, vectors, navigation, and notes.
- **Verification**: On the same 360-page Homo Deus file in a debug build, PDF processing fell from 116.38 s to 13.03 s; the complete package with 231 notes took 14.92 s. A fresh live app export succeeded, with PDF/mind map rendering and the reader More menu checked. The full 233-test suite passed, including the background 4,000-outline regression and mandatory performance/layout checks.

## Single-Package Imports Must Stay Scoped to the Imported Notebook

- **Trap**: A 132-note package had committed, but the importer still ran full-library discovery and repair on the UI thread. A stack sample showed SQLite reading unrelated card pages over SMB while collecting topic-to-book hashes. The shelf's old due-count query also read every card row.
- **Rule**: Apply a package directly through the importer transaction, including canonical document hashes and original-archive retention. Keep discovery and repair out of the explicit package path. Perform package reads, writes, and catalog loading off the main actor. Present conflict prompts on the main actor before the write transaction. Calculate due totals using the covering topic index and subtract future reviews, and check document paths only among candidate matches for the selected topic.
- **Verified**: The exact package completed on an isolated copy of the SMB library with about 18,700 existing cards. The app was idle by 25 seconds after confirmation and the PDF and mind map rendered. It preserved all 132 user note IDs and the original archive bytes. A second import showed the conflict prompt, and Cancel preserved the saved notebook. The reader More menu stayed within the window. The due-count query fell from about 50 seconds on the original library to under a second on the copy. All 255 tests passed, including the required benchmark and layout checks.
- **Follow-up profile**: On the same SMB library, repeating the topic counts, reading due card payloads a second time, and committing the first reader visit separately added variable latency after import. Package unpacking and parsing consistently took about 0.1 seconds.
- **Rule**: Count total and due notes together, and filter the loaded notebook cards using due IDs. Read the imported notebook, bookmarks, and shelf snapshot inside the import transaction while SQLite still has its pages. Save document recency in that transaction as well. Publish the workspace after commit and keep the original archive and SQLite durability guarantees.
- **Verified**: Instrumented replays went from 3.67–8.93 seconds to 2.34–2.43 seconds from package parsing through reader data preparation. The live app showed the imported PDF and mind map within 3.53 seconds, reopened the 132-note shelf entry, and kept the reader More menu inside the window. Note IDs, 11 link relationships, and original archive bytes matched the baseline. All 256 tests passed, including the required benchmark and layout checks.

## Org Export Uses the Notebook Snapshot

- **Trap**: Exporting the active canvas projection omits folded cards and other map layers. Raw excerpt lines can also look like Org headings or file directives, changing the parsed outline.
- **Rule**: Export the same complete, root-filtered card snapshot as the other notebook formats. Use explicit parents and the existing child-map projection, emit each note once, and preserve literal structural-looking body lines with Org example syntax. Keep the Org metadata in a property drawer and convert zero-based PDF indexes to one-based page numbers. Present text-export save panels as window-attached sheets and report write failures.
- **Toolbar sizing**: Count the enlarged hit-target frames, spacing, spacer minimum, and horizontal padding when adding controls to the mind map header. Their combined width must fit within the 320-point minimum pane. Otherwise SwiftUI centers the oversized row and clips the leading and trailing hit targets.
- **Verified**: All 236 tests passed, including the required performance and layout checks. Live Rock exports from the child map and the 320-point main pane produced identical files. Emacs parsed 471 unique note headings, matching every displayed notebook card. Cancel left no file. The final build rendered both panes, kept the reader More menu inside the window, and opened the existing Markdown save sheet.

- **Org-roam format**: Put the stable notebook ID at file scope and place all exported cards under one notebook heading. Use the notebook creation stamp and a lowercase, underscore-separated title slug limited to 60 columns. Keep PDF paths in the inherited Org Noter drawer only when there is one source document. For multiple sources, attach the matching path to the card. Bibliography references require a real citation key.

## Mind Map Toolbar Buttons Share One Layout

- **Trap**: A borderless SwiftUI menu applies native label insets and tint. Mixing it with plain icon buttons and giving actions different hit-target widths shifted the Share icon and broke the horizontal rhythm.
- **Rule**: Center symbols in the same 26-point icon frame and use 30-by-32-point plain button targets with uniform spacing. Give Share the same secondary foreground as Edit Card and Org Export in its default state. Host Share and Notebook Settings in the mind map pane's `InWindowPopoverContainer` and resolve their anchors from the triggers' actual bounds.
- **Verified**: Live Rock testing checked the alignment and inactive tint at normal and 320-point split widths. Share stayed inside the narrow pane, and Notebook Settings stayed inside the right window edge in MindMap Only. Markdown and Org opened their attached save sheets. Edit Card, search, outline, Back, settings dismissal, Split View restoration, and the reader More menu were exercised.
- **Optical alignment and spacing**: Centered symbols can still have different visible lower edges. Set the Share symbol to 12 points and lift it half a point within its fixed frame. Use the reader annotation groups' 6-point gap when space permits, and reduce only the gaps as the mind map pane approaches its 320-point minimum. Final live screenshots showed the Share, Edit Card, and Org glyphs ending on the same Retina pixel row at both widths. Share opened from outside the glyph, and the Share and reader More menus were contained and dismissible.


## Shared Ebib and Org-roam Files

- **Trap**: Re-serializing a bibliography can remove Ebib metadata and BibTeX macros.
  Replacing an existing linked Org export can destroy edited notes and create duplicate
  Org-roam IDs.
- **Rule**: Save a BibTeX edit against the current source range and reject a changed
  entry. Resolve existing bibliography records before ISBN lookup. Find literature
  files by their file-level citation key, preserve their Org IDs and hand-written
  content, and insert only card IDs that are missing. Keep PDF scanning and parsing
  off the main actor.
- **Reference layout**: Give the bibliography tabs a bounded height and allocate
  the remaining height to the list and detail panes. An unconstrained native split
  view can leave the list at the bottom of a tall shelf window.
- **Reference study links**: Store notebook links in the active library by
  bibliography path and citation key. Update topics in place to keep their links.
  Org export updates the resolved entry in its own bibliography, preserving existing
  attachments. Use the standard Study workspace for linked references so the PDF
  and the notebook open together, and keep the selected citation when returning.
- **BibTeX field editor**: Keep field identities and original UTF-8 source ranges
  while editing. Reuse the BibTeX lexer and patch only changed names, values, and
  separators. Unchanged macros and LaTeX groups must survive, even when their
  expanded values are displayed in the form. Keep coordinated saving and the
  unchanged-entry check for edits made concurrently in Ebib.
- **Multiline BibTeX values**: A rounded macOS TextField can accept line breaks
  while displaying only one line, even with a vertical axis. Use a wrapping
  TextEditor with bounded height so titles, abstracts, and pasted notes are
  readable without pushing the editor actions below the sheet.
- **Field suggestions**: Use the draft entry type for suggestions and exclude
  existing names case-insensitively. Treat suggestions as a convenience and
  validate custom names with the same rules used by the saved draft. Keep the
  picker within the editor sheet so the form and its scroll position survive.
  Derive a valid default from the filtered results because SwiftUI List can clear
  its selection while the rows change. After closing the picker, focus the new
  value editor once its row exists.
- **Reference search controls**: Share the clear button and focus behavior between
  the bibliography list and field picker. Reserve space for the button within
  the search bar and keep picker key handling on its input field.
