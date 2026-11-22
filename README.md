# MarginGraph

A native macOS application providing the full feature set of MarginNote 3:
- Multi-document PDF reading & excerpting
- Infinite 2D MindMap spatial graph
- Synchronized hierarchical outline
- Flashcard review with Spaced Repetition (SRS)
- Native MarginNote 3 database compatibility & import


## References and Org-roam

1. Open **Reference** and choose **Open Bibliography…**. Select the same UTF-8 `.bib`
   files you open in Ebib. Use **New Bibliography…** if you need an empty database.
   Pick the file that should receive new entries.
2. Choose **Literature Folder…** and select your Org-roam `literature` directory.
3. Add or edit a BibLaTeX entry directly, enter an ISBN with **From ISBN…**, or pick a
   PDF with **From PDF…**. PDF lookup checks the text, uses local OCR for scanned
   front matter, and queries Open Library by ISBN. PDF metadata and front matter
   provide a draft when a lookup returns no result or no ISBN is available.
4. Select an entry and use **Open Literature Note…** for a book or video. In a study
   notebook, **Export to Emacs Org** does the lookup and writes the linked note in
   one step. Existing reference keys and matching Org notes are reused. Re-export
   adds missing card IDs and preserves existing note text and headings.

MarginGraph writes the selected bibliography directly. Save pending edits in Ebib
before changing an entry in MarginGraph, and reload Ebib after an external edit.
