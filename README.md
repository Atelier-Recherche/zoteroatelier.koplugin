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
3. **Quittez complètement puis relancez** KOReader
4. Créez une clé API dans les [réglages Zotero](https://www.zotero.org/settings/keys) (notez le userID et la clé)
5. Si besoin, configurez WebDAV (voir plus bas)
6. Saisissez vos identifiants dans le menu du plugin, ou éditez le fichier de config

### Où copier le plugin

Le dossier **doit** s’appeler exactement `zoteroatelier.koplugin`.

Il doit contenir au minimum `main.lua` et `_meta.lua` :

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

| Plateforme | Chemin typique |
|------------|----------------|
| PC / Kobo / Kindle | `<install KOReader>/plugins/zoteroatelier.koplugin` |
| **Android** | `/sdcard/koreader/plugins/zoteroatelier.koplugin` |
| Alternative | `<répertoire data KOReader>/plugins/zoteroatelier.koplugin` |

Sur Android, le dossier dans l’APK est souvent **non accessible en écriture** — préférez `/sdcard/koreader/plugins/`.

Si vous migrez depuis l’ancien `zotero.koplugin`, renommez le dossier (ou remplacez-le), puis redémarrez. Les données locales restent dans `<data KOReader>/zotero/` (inchangé pour compatibilité).

### Où trouver le plugin dans KOReader

Ce plugin **n’apparaît pas** sous le menu Réglages (roue dentée) pour l’usage courant.

- **Utilisation :** menu du haut → **Recherche** (loupe) → **Zotero Atelier**, ou **Outils** → **Zotero Atelier**
- **Fichiers locaux / mappings :** Zotero Atelier → **Settings** → **Local files**
- **Activer / désactiver :** Réglages → **Plugin management** → **User plugins** → **Zotero Atelier**

### Le plugin n’apparaît pas ?

1. Vérifiez que le dossier se termine par `.koplugin`
2. Vérifiez que `main.lua` et `_meta.lua` sont *dans* ce dossier
3. Redémarrez KOReader complètement
4. Contrôlez **Plugin management → User plugins**
5. Sur Android : `/sdcard/koreader/plugins/zoteroatelier.koplugin`
6. Sinon, cherchez `zotero` / `zoteroatelier` dans `crash.log`

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
