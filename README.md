# Zotero Atelier pour KOReader

Plugin [KOReader](https://github.com/koreader/koreader) pour parcourir votre bibliothèque Zotero, ouvrir les pièces jointes, annoter (PDF / EPUB) et synchroniser les notes avec Zotero — y compris hors WebDAV.

> [!NOTE]
> Projet repris et développé sous le nom **Zotero Atelier** (fork / continuation du plugin Zotero pour KOReader). Version bêta : les retours et PR sont les bienvenus.

English version: [README.en.md](README.en.md)

## Fonctionnalités

* Synchronisation via l’API Web Zotero
* Ouverture des pièces jointes PDF / EPUB / HTML
* Annotations bidirectionnelles avec Zotero (création, modification, suppression)
* Écriture des surlignages **dans le PDF** (réglage activable) et/ou sync vers Zotero
* Annotations **EPUB** (sidecar KOReader ↔ Zotero ; position approximative / xpointers)
* Panneau **notes du document ouvert** (filtre, aller à la page, suppression)
* **Recherche globale** dans les annotations de la bibliothèque locale
* Téléchargement auto des collections marquées « offline »
* Stockage **WebDAV** (Nextcloud, etc.)
* **Fichiers locaux** hors WebDAV : dossier linked files, storage Zotero externe, mappings de chemins, recherche par nom de fichier, racines de recherche
* Recherche d’entrées par titre et premier auteur

### Limites actuelles

* La recherche bibliographique reste basique (pas encore tags / DOI / tous les auteurs)
* Sur EPUB, le positionnement exact type CFI Zotero n’est pas toujours parfait : texte, note et page/chapitre sont synchronisés en priorité
* Si vous activez à la fois l’écriture dans le PDF et la sync Zotero, les surlignages peuvent apparaître en double selon les viewers

## Installation

1. Utilisez une version récente de KOReader
2. Copiez le dossier du plugin (voir ci-dessous — **le nom doit finir par `.koplugin`**)
3. **Quittez complètement puis relancez** KOReader (pas seulement « retour »)
4. Créez une clé API dans les [réglages Zotero](https://www.zotero.org/settings/keys) (notez le userID et la clé)
5. Si besoin, configurez WebDAV (voir plus bas)
6. Saisissez vos identifiants dans le menu du plugin, ou éditez le fichier de config

### Où copier le plugin

Le dossier **doit** s’appeler exactement `zoteroatelier.koplugin`  
(pas `zotero.koplugin`, pas `zoteroatelier.koplugin-master`, pas un dossier imbriqué).

> [!IMPORTANT]
> Un ZIP GitHub s’appelle souvent `zoteroatelier.koplugin-master`.  
> **Renommez-le** en `zoteroatelier.koplugin` après extraction.  
> KOReader ignore tout dossier qui ne se termine pas exactement par `.koplugin`.

Il doit contenir **directement** (pas un sous-dossier) :

```
…/plugins/zoteroatelier.koplugin/
├── _meta.lua          ← obligatoire
├── main.lua           ← obligatoire
├── zoteroapi.lua
├── annotations.lua
├── annotation_panel.lua
├── annotation_search.lua
├── zoteroiteminfo.lua
└── …
```

**Mauvais** (ne charge pas) :
```
plugins/zoteroatelier.koplugin/zoteroatelier.koplugin-master/main.lua
plugins/zoteroatelier.koplugin-master/
plugins/zotero.koplugin/   ← ancien nom, ce fork utilise zoteroatelier
```

| Plateforme | Chemin typique |
|------------|----------------|
| PC / Kobo / Kindle | `<install KOReader>/plugins/zoteroatelier.koplugin` |
| **Android** | `/sdcard/koreader/plugins/zoteroatelier.koplugin` |
| Alternative | `<répertoire data KOReader>/plugins/zoteroatelier.koplugin` |

Sur Android, préférez `/sdcard/koreader/plugins/` (l’APK est souvent en lecture seule).

Les données restent dans `<data KOReader>/zotero/` (compatibilité avec l’ancien plugin).

### Où trouver le plugin dans KOReader

Après un redémarrage complet :

1. Menu du haut → **Recherche** (loupe) → **Zotero Atelier**
2. Menu du haut → **Outils** → **Zotero Atelier**
3. Menu du haut → **Réglages** (roue dentée) → **Zotero Atelier**
4. Pour l’activer : Réglages → **Plugin management** → **User plugins** → cochez **Zotero Atelier** → redémarrer

### Le plugin n’apparaît nulle part ?

1. Dossier = exactement `zoteroatelier.koplugin` (voir ci-dessus)
2. `main.lua` et `_meta.lua` sont **à la racine** de ce dossier
3. Redémarrage **complet** de KOReader
4. **Plugin management → User plugins** : case cochée (si « Zotero » ancien est désactivé, ce n’est pas le même plugin)
5. Android : `/sdcard/koreader/plugins/zoteroatelier.koplugin`
6. Ouvrez `crash.log` (répertoire data KOReader) et cherchez `zoteroatelier` / `Error when loading`

## Utilisation

Le plugin conserve la plupart des métadonnées en local. Hormis **Synchronize** (et le téléchargement d’un fichier manquant), il évite d’appeler le serveur.

### Browse

Navigation dans les collections. Seuls les items avec au moins une pièce jointe supportée sont listés. Collections d’abord, puis items (ordre alphabétique). Les items sans collection sont à la racine.

- **Tap :** ouvrir une sous-collection ou une pièce jointe (téléchargement si besoin) ; les annotations Zotero connues sont attachées au sidecar
- **Appui long :** collection → offline ; item → fiche biblio + liste des pièces jointes
- **Loupe :** recherche titre / premier auteur

Geste possible : Réglages → Gestures → General → **Zotero Collection Browser**

### Synchronize

La première sync télécharge toutes les métadonnées (peut être long). Ensuite, sync incrémentale.

1. Envoi des annotations locales (création / édition / suppression)
2. Téléchargement des collections
3. Téléchargement / catalogue des items
4. Téléchargement des pièces jointes des collections offline

### Annotations & notes

Dans le menu **Zotero Atelier** :

| Entrée | Rôle |
|--------|------|
| **Document annotations** | Liste filtrable des notes du document ouvert (aller à la page, supprimer) |
| **Search annotations** | Recherche dans les annotations de toute la biblio syncée |
| **Sync document annotations** | Envoi immédiat create/update/delete pour le fichier ouvert |
| **Write highlights into PDF files** | Active l’écriture des surlignages dans le fichier PDF |

La sync des annotations se déclenche aussi à l’ouverture et à la fermeture d’un document reconnu comme pièce jointe Zotero.

### Maintenance

- **Re-analyse local items** : recalcule attachments / annotations sans réseau
- **Re-scan storage** : indexe les fichiers déjà présents localement
- **Resync entire collection** : remet la base locale à zéro puis resync complète (dernier recours)

### Settings — Local files

Utile quand les PDF ne sont **pas** sur le stockage Zotero / WebDAV :

- Dossier **linked files** (fichiers liés Zotero)
- Dossier **external Zotero storage** (`storage/KEY/fichier`)
- **Prefer local files** / **Allow outdated local files**
- **Search root folders** + recherche par nom de fichier
- **Path mappings** (préfixe PC → préfixe liseuse) et assistant **Suggest path mapping**

### About/Info

Version du plugin et statistiques de la bibliothèque locale.

---

## Configuration

### WebDAV

Pour stocker les pièces jointes ailleurs que chez Zotero (ex. Nextcloud), voir le [manuel Zotero](https://www.zotero.org/support/sync).

L’URL WebDAV doit pointer vers un répertoire nommé `zotero`, par ex.  
`https://votre-instance.tld/remote.php/dav/files/votre-user/zotero`  
Préférez un mot de passe d’application.

### Configuration manuelle

Fichier `<data KOReader>/zotero/meta.lua` :

```lua
return {
    ["api_key"] = "",           -- clé API Zotero
    ["user_id"] = "",           -- user ID (entier)
    ["webdav_enabled"] = false,
    ["webdav_url"] = "",
    ["webdav_user"] = "",
    ["webdav_password"] = "",
    ["prefer_local_files"] = true,
    ["linked_files_enabled"] = false,
    ["linked_files_base"] = "",
    ["external_storage_enabled"] = false,
    ["external_storage_dir"] = "",
    ["allow_stale_local"] = true,
    ["auto_disable_pdf_writing"] = false, -- false = écrire les highlights dans le PDF
    ["path_mappings"] = {},
    ["search_roots"] = {},
}
```

### PDF : écrire ou non dans le fichier

Par défaut, Zotero Atelier **active** l’écriture des surlignages dans le PDF à l’ouverture depuis le navigateur (réglage « Write highlights into PDF files »).  
Désactivez cette option dans le plugin si vous préférez ne garder les notes que dans le sidecar / Zotero.

Réglage global KOReader : Réglages → Document → Save document (write highlights into PDF).

---

## Crédits

Basé sur le plugin Zotero pour KOReader (communauté / forks successifs).  
**Zotero Atelier** — reprise et extensions (annotations, notes, fichiers locaux).
