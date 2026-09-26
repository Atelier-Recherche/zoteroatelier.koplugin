# Zotero Atelier for KOReader

[KOReader](https://github.com/koreader/koreader) plugin to browse your Zotero library, open attachments, annotate (PDF / EPUB), and sync notes with Zotero — including when files are not on WebDAV.

> [!NOTE]
> Continued as **Zotero Atelier** (fork / continuation of the Zotero KOReader plugin). Beta: bug reports and PRs welcome.

Version française : [README.md](README.md)

## Features

* Sync via Zotero Web API
* Open PDF / EPUB / HTML attachments
* Bidirectional annotation sync (create, update, delete)
* Write highlights **into the PDF** (toggle) and/or sync to Zotero
* **EPUB** annotations (KOReader sidecar ↔ Zotero; approximate position / xpointers)
* **Document annotations** panel (filter, jump to page, delete)
* **Global search** across annotations in the local library
* Auto-download for offline collections
* **WebDAV** storage
* **Local files** without WebDAV: linked-files folder, external Zotero storage, path mappings, basename search, search roots
* Search entries by title and first author

### Limitations

* Bibliographic search is still basic (no full tags / DOI / all authors yet)
* EPUB exact CFI positioning may be imperfect; text, note, and page/chapter sync first
* Enabling both in-PDF writing and Zotero sync can show duplicate highlights depending on the viewer

## Installation

1. Use a recent KOReader build
2. Install the plugin folder (name **must** end with `.koplugin`)
3. **Fully quit and restart** KOReader
4. Create an API key in [Zotero Settings](https://www.zotero.org/settings/keys)
5. Configure WebDAV if needed
6. Enter credentials in the plugin menu or edit the config file

### Where to copy the plugin

The directory **must** be named exactly `zoteroatelier.koplugin`:

```
zoteroatelier.koplugin/
├── _meta.lua
├── main.lua
├── zoteroapi.lua
├── annotations.lua
├── annotation_panel.lua
├── annotation_search.lua
└── …
```

| Platform | Typical path |
|----------|----------------|
| PC / Kobo / Kindle | `<KOReader install>/plugins/zoteroatelier.koplugin` |
| **Android** | `/sdcard/koreader/plugins/zoteroatelier.koplugin` |
| Alternative | `<KOReader data directory>/plugins/zoteroatelier.koplugin` |

Migrating from `zotero.koplugin`: rename/replace the folder and restart. Local data stays in `<KOReader data>/zotero/` for compatibility.

### Finding the plugin in KOReader

- Top menu → **Search** → **Zotero Atelier**, or **Tools** → **Zotero Atelier**
- Local files: Zotero Atelier → **Settings** → **Local files**
- Enable/disable: Settings → **Plugin management** → **User plugins** → **Zotero Atelier**

## Usage

Most library metadata stays on device. Apart from **Synchronize** (and downloading a missing file), the plugin avoids hitting the Zotero server.

### Browse / Synchronize / Maintenance

Same workflow as before: browse collections, incremental sync, re-analyze / rescan / full resync.

### Annotations & notes

| Menu item | Role |
|-----------|------|
| **Document annotations** | Filterable list for the open document |
| **Search annotations** | Search all synced annotations |
| **Sync document annotations** | Immediate create/update/delete for the open file |
| **Write highlights into PDF files** | Enable writing highlights into the PDF |

Annotation sync also runs on open/close when the file matches a Zotero attachment.

### Local files

For PDFs not on Zotero storage / WebDAV: linked-files base, external storage (`storage/KEY/file`), path mappings, search roots, basename fallback, allow stale local files.

## Configuration

Edit `<KOReader data>/zotero/meta.lua` (see French README for the full key list). WebDAV URL must point to a directory named `zotero`.

By default Zotero Atelier **enables** writing highlights into PDFs opened from the browser; turn that off in plugin settings if you prefer sidecar/Zotero only.

## Credits

Based on the community Zotero KOReader plugin and subsequent forks.  
**Zotero Atelier** — continued development (annotations, notes, local files).
