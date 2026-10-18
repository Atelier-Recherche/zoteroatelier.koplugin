import sqlite3, re, json

meta = open(r"d:/Code/ATzotero.koplugin/_tmp_orain_meta.lua", encoding="utf-8", errors="replace").read()
print("=== SIDECAR ANNOTATIONS ===")
# split by annotation blocks roughly
pages = re.findall(r'\["page"\]\s*=\s*([^\n,]+)', meta)
pos0 = re.findall(r'\["pos0"\]\s*=\s*([^\n,]+)', meta)
pos1 = re.findall(r'\["pos1"\]\s*=\s*([^\n,]+)', meta)
keys = re.findall(r'\["zoteroKey"\]\s*=\s*"([^"]+)"', meta)
drawers = re.findall(r'\["drawer"\]\s*=\s*"([^"]+)"', meta)
colors = re.findall(r'\["color"\]\s*=\s*"([^"]+)"', meta)
texts = re.findall(r'\["text"\]\s*=\s*"([^"]*)"', meta)
print("count keys", len(keys), keys)
print("pages", pages)
print("pos0", pos0)
print("pos1", pos1)
print("drawers", drawers)
print("colors", colors)
print("texts", [t[:40] for t in texts[:10]])
for k in ("annotations_paging", "annotations_rolling", "zoteroLibVersion"):
    print(k, "yes" if f'["{k}"]' in meta else "no")

db = sqlite3.connect(r"d:/Code/ATzotero.koplugin/_tmp_zotero.db")
c = db.cursor()
print("\n=== DB itemAnnotations ===")
for r in c.execute(
    """
SELECT i.key, i.version, p.key
FROM itemAnnotations ia
JOIN items i ON ia.itemID=i.itemID
JOIN items p ON ia.parentItemID=p.itemID
"""
):
    print(r)

print("\n=== annotation JSON parents for ACZG7K8Q ===")
for k, v in c.execute(
    "SELECT items.key, itemData.value FROM items JOIN itemData ON items.itemID=itemData.itemID"
):
    try:
        j = json.loads(v)
    except Exception:
        continue
    d = j.get("data") or {}
    if d.get("itemType") == "annotation" and d.get("parentItem") == "ACZG7K8Q":
        pos = d.get("annotationPosition")
        try:
            posj = json.loads(pos) if isinstance(pos, str) else pos
        except Exception:
            posj = pos
        print(
            k,
            "type",
            d.get("annotationType"),
            "color",
            d.get("annotationColor"),
            "text",
            repr((d.get("annotationText") or "")[:40]),
            "pos",
            posj,
        )
