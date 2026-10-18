import re
text = open(r"d:/Code/ATzotero.koplugin/_tmp_orain_meta.lua", encoding="utf-8", errors="replace").read()
# print each annotation summary
blocks = re.split(r'\n\s*\[\d+\]\s*=\s*\{', text)
for i, b in enumerate(blocks[1:], 1):
    key = re.search(r'zoteroKey.*=.*"([^"]+)"', b)
    drawer = re.search(r'drawer.*=.*"([^"]+)"', b)
    color = re.search(r'color.*=.*"([^"]+)"', b)
    note = re.search(r'\["note"\]\s*=\s*"([^"]*)"', b)
    cfi = re.search(r'zoteroCfi.*=.*"([^"]+)"', b)
    page = re.search(r'\["page"\]\s*=\s*"([^"]+)"', b)
    pos0 = re.search(r'\["pos0"\]\s*=\s*"([^"]+)"', b)
    pos1 = re.search(r'\["pos1"\]\s*=\s*"([^"]+)"', b)
    text_ = re.search(r'\["text"\]\s*=\s*"([^"]*)"', b)
    print("---", i, key.group(1) if key else "?")
    print("  drawer", drawer.group(1) if drawer else None, "color", color.group(1) if color else None)
    print("  note", (note.group(1)[:40] if note else None))
    print("  text", (text_.group(1)[:40] if text_ else None))
    print("  page", page.group(1) if page else None)
    print("  pos0", pos0.group(1) if pos0 else None)
    print("  pos1", pos1.group(1) if pos1 else None)
    print("  cfi", cfi.group(1) if cfi else None)
    if cfi and "," not in cfi.group(1):
        print("  *** NO RANGE CFI ***")
