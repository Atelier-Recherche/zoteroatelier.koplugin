import re, json, sqlite3

meta = open(r"d:/Code/ATzotero.koplugin/_tmp_orain_meta.lua", encoding="utf-8", errors="replace").read()
# Find annotations by text fragments
for needle in ["économiste", "dévoile ce", "Présentation", "Hhhhhh", "compagnies"]:
    idx = meta.find(needle)
    print(f"\n=== needle {needle!r} idx={idx} ===")
    if idx < 0:
        continue
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
    for field in ("zoteroKey", "color", "drawer", "zoteroCfi", "page", "pos0", "pos1", "text", "note"):
        m = re.search(rf'\["{field}"\]\s*=\s*"((?:\\.|[^"\\])*)"', block)
        if m:
            val = m.group(1).replace("\\n", "\n")[:80]
            print(f"  {field}: {val}")

print("\n=== DB annotations for ACZG7K8Q ===")
c = sqlite3.connect(r"d:/Code/ATzotero.koplugin/_tmp_zotero.db").cursor()
for k, v in c.execute(
    "SELECT items.key, itemData.value FROM items JOIN itemData ON items.itemID=itemData.itemID"
):
    try:
        j = json.loads(v)
    except Exception:
        continue
    d = j.get("data") or {}
    if d.get("itemType") != "annotation" or d.get("parentItem") != "ACZG7K8Q":
        continue
    text = (d.get("annotationText") or "")[:60]
    print(k, d.get("annotationType"), d.get("annotationColor"), repr(text))
    print("  CFI:", d.get("annotationPosition"))
