-- Use core gettext only here: _meta.lua is loaded before the plugin path
-- is always on package.path, so require("zotero_i18n") can fail and hide the plugin.
local _ = require("gettext")

return {
    -- Plugin id = folder name (zoteroatelier.koplugin → zoteroatelier).
    -- Do not rely on a "name" field here (deprecated in recent KOReader).
    fullname = _("Zotero Atelier"),
    description = _([[
Zotero library in KOReader: browse, sync, PDF/EPUB annotations, local files.

Where to find it:
• Top menu → Search (magnifier) → Zotero Atelier
• Top menu → Tools → Zotero Atelier
• Top menu → Settings (gear) → Zotero Atelier
• Enable: Settings → Plugin management → User plugins → Zotero Atelier

Required folder: zoteroatelier.koplugin (with main.lua and _meta.lua at its root).
Fully restart KOReader after install.]]),
}
