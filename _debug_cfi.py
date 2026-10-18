"""Extract spine HTML and debug CFI for Hhhhhh annotation."""
import json, re, sqlite3, subprocess, tempfile, os

meta = open(r"d:/Code/ATzotero.koplugin/_tmp_orain_meta.lua", encoding="utf-8", errors="replace").read()
# Find block with Hhhhhh
idx = meta.find("Hhhhhh")
print("found Hhhhhh at", idx)
start = meta.rfind("[", 0, idx)
# find annotation table start
start = meta.rfind("\n        [", 0, idx)
brace = meta.find("{", start)
depth = 0
end = None
for i in range(brace, len(meta)):
    if meta[i] == "{":
        depth += 1
    elif meta[i] == "}":
        depth -= 1
        if depth == 0:
            end = i + 1
            break
block = meta[start:end]
print("BLOCK:\n", block)

epub = r"/sdcard/Documents/Notes/Lectures/Divers/Arnaud Orain - Le monde confisqué_ Essai sur le capitalisme de la finitude.epub"
# pull spine item 4 (couv) - DocFragment[4]
# get href from opf
opf = subprocess.check_output(
    ["adb", "shell", f"unzip -p {repr(epub)[1:-1]} OEBPS/content.opf"],
    text=True,
    errors="replace",
)
# parse spine
manifest = {}
for m in re.finditer(r'<item\s+[^>]*>', opf):
    item = m.group(0)
    iid = re.search(r'id="([^"]+)"', item)
    href = re.search(r'href="([^"]+)"', item)
    if iid and href:
        manifest[iid.group(1)] = href.group(1)
spine = re.findall(r'<itemref[^>]+idref="([^"]+)"', opf)
print("spine[0:6]", [(i + 1, s, manifest.get(s)) for i, s in enumerate(spine[:6])])
href4 = manifest.get(spine[3])  # 1-based fragment 4 → index 3
print("fragment 4 href", href4)
entry = "OEBPS/" + href4 if href4 and not href4.startswith("OEBPS") else href4
# Actually opf is in OEBPS/, href is relative to OEBPS
if href4 and not href4.startswith("/"):
    entry = "OEBPS/" + href4
print("entry", entry)

html = subprocess.check_output(
    ["adb", "shell", f"unzip -p {repr(epub)[1:-1]} {entry}"],
    text=True,
    errors="replace",
)
open(r"d:/Code/ATzotero.koplugin/_tmp_frag4.xhtml", "w", encoding="utf-8").write(html)
print("html len", len(html))
print("html head", html[:500])
# show paragraph structure
for i, m in enumerate(re.finditer(r'<p[\s>]', html, re.I)):
    if i < 8:
        snippet = html[m.start() : m.start() + 200].replace("\n", " ")
        print(f"p@{m.start()}: {snippet[:180]}")

# DB item for this key
key_m = re.search(r'zoteroKey"\]\s*=\s*"([^"]+)"', block)
key = key_m.group(1) if key_m else None
print("key", key)
if key:
    c = sqlite3.connect(r"d:/Code/ATzotero.koplugin/_tmp_zotero.db").cursor()
    row = c.execute(
        "SELECT value FROM itemData JOIN items ON itemData.itemID=items.itemID WHERE items.key=?",
        (key,),
    ).fetchone()
    if row:
        j = json.loads(row[0])
        print("DB annotationPosition:", j.get("data", {}).get("annotationPosition"))
        print("DB type/color/text:", j.get("data", {}).get("annotationType"), j.get("data", {}).get("annotationColor"), repr((j.get("data", {}).get("annotationText") or "")[:60]))
