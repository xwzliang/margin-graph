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
3. Use **Add Entry…** or **Edit…** to change individual field names and values.
   **Add Field** lets you search common fields for the entry type or enter a custom
   name. The minus button removes a field.
   You can also enter an ISBN with **From ISBN…** or pick a PDF with **From PDF…**.
   PDF lookup checks the text, uses local OCR for scanned front matter, and queries
   Open Library by ISBN. PDF metadata and front matter
   provide a draft when a lookup returns no result or no ISBN is available.
4. Select an entry and choose **Open PDF & Mind Map** to open its study workspace.
   Use **Link Notebook…** or **Locate PDF…** when MarginGraph needs help finding it.
   **Open Literature Note…** opens the Org-roam note for a book or video.
5. In a study notebook, **Export to Emacs Org** attaches the source PDF to its
   BibTeX entry, links the entry to the notebook, and exports the literature note.
   Re-export reuses the citation key, keeps previous attachments, and adds missing
   card IDs to the existing Org note while preserving its text and headings.

MarginGraph writes the selected bibliography directly. Save pending edits in Ebib
before changing an entry in MarginGraph, and reload Ebib after an external edit.
