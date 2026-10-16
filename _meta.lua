local _ = require("gettext")

return {
    -- Plugin id = folder name (zoteroatelier.koplugin → zoteroatelier).
    -- Do not rely on a "name" field here (deprecated in recent KOReader).
    fullname = _("Zotero Atelier"),
    description = _([[
Bibliothèque Zotero dans KOReader : parcours, sync, annotations PDF/EPUB, fichiers locaux.

Où le trouver :
• Menu du haut → Recherche (loupe) → Zotero Atelier
• Menu du haut → Outils → Zotero Atelier
• Menu du haut → Réglages (roue) → Zotero Atelier
• Activer : Réglages → Plugin management → User plugins → Zotero Atelier

Dossier obligatoire : zoteroatelier.koplugin (avec main.lua et _meta.lua directement dedans).
Redémarrage complet de KOReader après installation.]]),
}
