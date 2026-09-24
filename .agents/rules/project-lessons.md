# Project Lessons & Mandatory Engineering Rules

> [!IMPORTANT]
> **MANDATORY AGENT WORKFLOW RULE**:
> 1. **Before any coding, debugging, or refactoring**: Consult the lessons and traps in this file to avoid re-introducing documented regressions or fighting known framework pitfalls.
> 2. **Before concluding ANY task**: If the task involved diagnosing an unexpected bug, fixing broken behavior (such as blocked clicks, layout shifts, coordinate offsets, performance lag, or stuck cursors), or learning a non-obvious framework behavior (SwiftUI, AppKit, PDFKit, SQLite), **YOU MUST PROACTIVELY UPDATE THIS FILE** before declaring completion.
> 3. **Definition of Done**: Updating this file with verified traps and durable rules is part of the definition of done for non-trivial tasks. Do not wait for the user to ask or remind you.

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
- Swift Concurrency: `Database` uses serial queue synchronization and `@unchecked Sendable` for thread-safe concurrent access across SwiftUI views.

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
